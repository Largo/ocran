#include <windows.h>
#include <string.h>
#include <stdio.h>
#include "error.h"
#include "filesystem_utils.h"
#include "inst_dir.h"

static char **transform_argv(char *argv[])
{
    size_t argc = 0;
    for (char **p = argv; *p; p++) argc++;

    if (argc <= 0) {
        APP_ERROR("No arguments to transform");
        return NULL;
    }

    char **out_argv = calloc(argc + 1, sizeof(*out_argv));
    if (!out_argv) {
        APP_ERROR("Memory allocation failed in transform_argv");
        return NULL;
    }

    for (size_t i = 0; i < argc; i++) {
        char *str;
        switch (i) {
            case 0:
                str = strdup(argv[0]);
                break;

            case 1:
                str = ExpandInstDirPath(argv[1]);
                break;

            default:
                str = ReplaceInstDirPlaceholder(argv[i]);
                break;
        }
        if (!str) {
            APP_ERROR("Failed to transform argv[%d]", i);
            goto cleanup;
        }
        out_argv[i] = str;
    }

    out_argv[argc] = NULL;
    return out_argv;

cleanup:
    for (size_t j = 0; j < argc; j++) free(out_argv[j]);
    free(out_argv);
    return NULL;
}

/**
 * Splits the NULL-delimited strings in buffer and stores pointers in array.
 *
 * @param buffer      Pointer to data containing NULL-delimited strings.
 * @param buffer_size Size in bytes of buffer.
 * @param array       Array to receive string pointers. If NULL, only counting
 *                    is performed.
 * @param array_count Number of elements array can hold (excluding the NULL
 *                    terminator). Caller must allocate with
 *                    calloc(array_count + 1, sizeof(*array)).
 * @return            Number of strings in buffer (excluding the NULL
 *                    terminator).
 */
static size_t split_strings_to_array(const char *buffer, size_t buffer_size,
                                     char **array, size_t array_count)
{
    size_t needed   = 0;
    size_t stored   = 0;
    const char *p   = buffer;
    const char *end = buffer + buffer_size;

    while (p < end) {
        const char *nul = memchr(p, '\0', (size_t)(end - p));
        if (!nul) {
            break;
        }
        if (array && stored < array_count) {
            array[stored++] = (char *)p;
        }
        needed++;
        p = nul + 1;
        if (*p == '\0') {
            break;
        }
    }

    if (array && array_count > 0) {
        array[stored] = NULL;
    }
    return needed;
}

static char **info_to_argv(const char *info, size_t info_size)
{
    size_t argc = split_strings_to_array(info, info_size, NULL, 0);
    size_t argv_size = (argc + 1) * sizeof(char *);
    void *base = malloc(argv_size + info_size);
    if (!base) {
        APP_ERROR("Memory allocation failed for argv");
        return NULL;
    }
    char **argv = (char **)base;
    char  *args = (char *) base + argv_size;
    memcpy(args, info, info_size);

    size_t stored = split_strings_to_array(args, info_size, argv, argc);
    if (stored != argc) {
        APP_ERROR("Argument count mismatch");
        free(base);
        return NULL;
    }
    return argv;
}

static char **ScriptARGV = NULL;

#define HAS_SCRIPT_INFO (ScriptARGV)

bool GetScriptInfo(const char **app_name, char **cmd_line)
{
    if (HAS_SCRIPT_INFO) {
        *app_name = NULL;
        *cmd_line = NULL;
        return true;
    } else {
        return false;
    }
}

bool InitializeScriptInfo(const char *info, size_t info_size)
{
    if (HAS_SCRIPT_INFO) {
        APP_ERROR("Script info is already set");
        return false;
    }

    if (info_size < 2
        || info[info_size - 1] != '\0'
        || info[info_size - 2] != '\0') {
        APP_ERROR("Script info not double-NULL terminated");
        return false;
    }

    const char *argv0 = info;
    if (*argv0 == '\0') {
        APP_ERROR("Application name is empty");
        return false;
    }

    if (!IsCleanRelativePath(argv0)) {
        APP_ERROR("Application name contains prohibited relative path elements");
        return false;
    }

    const char *argv1 = argv0 + strlen(info) + 1;
    if (*argv1 == '\0') {
        APP_ERROR("Script name is empty");
        return false;
    }

    if (!IsCleanRelativePath(argv1)) {
        APP_ERROR("Script name contains prohibited relative path elements");
        return false;
    }

    char **argv = info_to_argv(info, info_size);
    if (!argv) {
        APP_ERROR("Failed to convert script info to argv");
        return false;
    }

    ScriptARGV = argv;
    return true;
}

void FreeScriptInfo(void)
{
    if (ScriptARGV) {
        free(ScriptARGV);
        ScriptARGV = NULL;
    }
}

static char **shallow_merge_argv(char *argv1[], char *argv2[])
{
    size_t c1 = 0;
    for (char **p = argv1; *p; p++) c1++;

    size_t c2 = 0;
    for (char **p = argv2; *p; p++) c2++;

    size_t outc = c1 + c2;
    char **outv = calloc(outc + 1, sizeof(*outv));
    if (!outv) {
        APP_ERROR("Memory allocation failed for merged argv");
        return NULL;
    }

    memcpy(outv,      argv1, sizeof(*outv) * c1);
    memcpy(outv + c1, argv2, sizeof(*outv) * c2);
    outv[outc] = NULL;
    return outv;
}

bool RunScript(char *argv[], int *exit_code)
{
    if (!HAS_SCRIPT_INFO) {
        APP_ERROR("Script info is not initialized");
        return false;
    }

    if (!argv || !*argv) {
        APP_ERROR("argv is NULL or empty");
        return false;
    }

    bool result = false;
    char *app_name = NULL;
    char **script_argv = NULL;
    char **merged_argv = NULL;

    app_name = ExpandInstDirPath(ScriptARGV[0]);
    if (!app_name) {
        APP_ERROR("Failed to expand application name to installation directory");
        goto cleanup;
    }

    script_argv = transform_argv(ScriptARGV);
    if (!script_argv) {
        APP_ERROR("Failed to transform argv");
        goto cleanup;
    }

    merged_argv = shallow_merge_argv(script_argv, argv + 1);
    if (!merged_argv) {
        APP_ERROR("Failed to merge script arguments with extra arguments");
        goto cleanup;
    }

    result = CreateAndWaitForProcess(app_name, merged_argv, exit_code);

cleanup:
    if (app_name) {
        free(app_name);
    }
    if (script_argv) {
        for (char **p = script_argv; *p; p++) {
            free(*p);
        }
        free(script_argv);
    }
    if (merged_argv) {
        free(merged_argv);
    }
    return result;
}
