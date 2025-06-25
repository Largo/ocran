#include <windows.h>
#include <string.h>
#include <stdio.h>
#include "error.h"
#include "filesystem_utils.h"
#include "inst_dir.h"

static char **transform_argv(const char *argv[])
{
    size_t argc = 0;
    for (const char **p = argv; *p; p++) argc++;

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
                                     const char **array, size_t array_count)
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
            array[stored++] = p;
        }
        needed++;
        p = nul + 1;
    }

    if (array && array_count > 0) {
        array[stored] = NULL;
    }
    return needed;
}

static char *Script_ApplicationName = NULL;
static char *Script_CommandLine = NULL;
static char **ScriptARGV = NULL;

#define HAS_SCRIPT_INFO (Script_ApplicationName && ScriptARGV)

bool GetScriptInfo(const char **app_name, char **cmd_line)
{
    if (HAS_SCRIPT_INFO) {
        *app_name = Script_ApplicationName;
        *cmd_line = Script_CommandLine;
        return true;
    } else {
        return false;
    }
}

bool InitializeScriptInfo(const char *args, size_t args_size)
{
    if (HAS_SCRIPT_INFO) {
        APP_ERROR("Script info is already set");
        return false;
    }

    char *application_name = NULL;
    size_t argc;
    const char **argv = NULL;
    char **script_argv = NULL;
    bool result = false;

    argc = split_strings_to_array(args, args_size, NULL, 0);

    if (argc < 2) {
        APP_ERROR("Insufficient arguments expected at least application and script name");
        goto cleanup;
    }

    argv = calloc(argc + 1, sizeof(*argv));
    if (!argv) {
        APP_ERROR("Memory allocation failed for argv");
        goto cleanup;
    }

    size_t needed = split_strings_to_array(args, args_size, argv, argc);
    if (needed != argc) {
        APP_ERROR("Argument count mismatch");
        goto cleanup;
    }

    if (!IsCleanRelativePath(argv[0])) {
        APP_ERROR("Application name contains prohibited relative path elements like '.' or '..'");
        goto cleanup;
    }

    if (!IsCleanRelativePath(argv[1])) {
        APP_ERROR("Script name contains prohibited relative path elements like '.' or '..'");
        goto cleanup;
    }

    // Set Script_ApplicationName
    application_name = ExpandInstDirPath(argv[0]);
    if (!application_name) {
        APP_ERROR("Failed to expand application name to installation directory");
        goto cleanup;
    }

    // Set Script_CommandLine
    script_argv = transform_argv(argv);
    if (!script_argv) {
        APP_ERROR("Failed to transform argv");
        goto cleanup;
    }

    ScriptARGV = script_argv;
    Script_ApplicationName = application_name;
    result = true;

cleanup:
    if (!result) {
        free(application_name);

        if (script_argv) {
            for (char **p = script_argv; *p; p++) {
                free(*p);
            }
            free(script_argv);
        }
    }
    free(argv);
    return result;
}

void FreeScriptInfo(void)
{
    free(Script_ApplicationName);
    Script_ApplicationName = NULL;

    free(Script_CommandLine);
    Script_CommandLine = NULL;
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

bool RunScript(int argc, char *argv[], int *exit_code)
{
    if (!HAS_SCRIPT_INFO) {
        APP_ERROR("Script info is not initialized");
        return false;
    }

    bool result = false;

    char **merged_argv = shallow_merge_argv(ScriptARGV, argv + 1);
    if (!merged_argv) {
        APP_ERROR("Failed to merge script arguments with extra arguments");
        goto cleanup;
    }

    result = CreateAndWaitForProcess(Script_ApplicationName, merged_argv, exit_code);

cleanup:
    free(merged_argv);
    return result;
}
