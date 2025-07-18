#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include "error.h"
#include "system_utils.h"
#include "inst_dir.h"
#include "script_info.h"

/**
 * Splits the NULL-delimited strings in buffer and stores pointers in array.
 *
 * @param buffer      Pointer to data containing NULL-delimited strings.
 *                    The buffer must be terminated by a double NULL character.
 * @param array       Array to receive string pointers. If NULL, only counting
 *                    is performed.
 * @return            Number of strings in buffer (excluding the NULL
 *                    terminator).
 */
static size_t split_strings_to_array(const char *buffer, char **array)
{
    size_t count = 0;

    for (const char *p = buffer; *p; p++) {
        if (array) {
            array[count] = (char *)p;
        }
        count++;

        while (*p) p++;
    }

    if (array) {
        array[count] = NULL;
    }
    return count;
}

static char **info_to_argv(const char *info, size_t info_size)
{
    size_t argc = split_strings_to_array(info, NULL);
    size_t argv_size = (argc + 1) * sizeof(char *);
    void *base = malloc(argv_size + info_size);
    if (!base) {
        APP_ERROR("Memory allocation failed for argv");
        return NULL;
    }
    char **argv = (char **)base;
    char  *args = (char *) base + argv_size;
    memcpy(args, info, info_size);
    split_strings_to_array(args, argv);
    return argv;
}

static char **ScriptInfo = NULL;

static inline bool IsScriptInfoSet(void) {
    return ScriptInfo != NULL;
}

char **GetScriptInfo(void)
{
    if (!IsScriptInfoSet()) {
        return NULL;
    }

    size_t stored = 0;
    for (char **p = ScriptInfo; *p; p++) stored++;
    if (stored == 0) {
        APP_ERROR("ScriptInfo is empty");
        return NULL;
    }
    char *last = ScriptInfo[stored - 1];

    char *end = last + strlen(last) + 1 + 1;  // double-NULL terminated
    size_t infov_size = end - (char *)ScriptInfo;
    char **argv = malloc(infov_size);
    if (!argv) {
        APP_ERROR("Memory allocation failed for GetScriptInfo");
        return NULL;
    }
    memcpy(argv, ScriptInfo, infov_size);
    return argv;
}

bool SetScriptInfo(const char *info, size_t info_size)
{
    if (IsScriptInfoSet()) {
        APP_ERROR("Script info is already set");
        return false;
    }

    if (!info) {
        APP_ERROR("info is NULL");
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

    ScriptInfo = argv;
    return true;
}

void FreeScriptInfo(void)
{
    if (ScriptInfo) {
        free(ScriptInfo);
        ScriptInfo = NULL;
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

bool RunScript(char *argv[], bool is_chdir_to_script_dir, int *exit_code)
{
    if (!IsScriptInfoSet()) {
        APP_ERROR("Script info is not initialized");
        return false;
    }

    if (!argv || !*argv) {
        APP_ERROR("argv is NULL or empty");
        return false;
    }

    bool result = false;
    char **script_info = GetScriptInfo();
    char *app_name = NULL;
    char *script_name = NULL;
    char **merged_argv = NULL;
    char *script_dir = NULL;

    app_name = ExpandInstDirPath(script_info[0]);
    if (!app_name) {
        APP_ERROR("Failed to expand application name to installation directory");
        goto cleanup;
    }

    script_name = ExpandInstDirPath(script_info[1]);
    if (!script_name) {
        APP_ERROR("Failed to expand script name to installation directory");
        goto cleanup;
    }

    script_info[1] = script_name;

    merged_argv = shallow_merge_argv(script_info, argv + 1);
    if (!merged_argv) {
        APP_ERROR("Failed to merge script arguments with extra arguments");
        goto cleanup;
    }

    if (is_chdir_to_script_dir) {
        script_dir = GetParentPath(script_name);
        if (!script_dir) {
            APP_ERROR("Failed to build path for script directory");
            goto cleanup;
        }

        DEBUG(
            "Changing working directory to script directory '%s'",
            script_dir
        );

        char *ruby_optv[5] = { script_info[0], "-C", script_dir, "--", NULL };
        char **new_argv = shallow_merge_argv(ruby_optv, merged_argv + 1);
        if (!new_argv) {
            APP_ERROR("Failed to merge script arguments with extra arguments");
            goto cleanup;
        }
        free(merged_argv);
        merged_argv = new_argv;
    }

    result = CreateAndWaitForProcess(app_name, merged_argv, exit_code);

cleanup:
    if (script_info) {
        free(script_info);
    }
    if (app_name) {
        free(app_name);
    }
    if (script_name) {
        free(script_name);
    }
    if (merged_argv) {
        free(merged_argv);
    }
    if (script_dir) {
        free(script_dir);
    }
    return result;
}
