#include <windows.h>
#include <string.h>
#include <stdio.h>
#include "error.h"
#include "filesystem_utils.h"
#include "inst_dir.h"

// concat_with_space - join two strings with a single space between
static char *concat_with_space(const char *a, const char *b)
{
    size_t len = strlen(a) + 1 + strlen(b) + 1;
    char *out = calloc(len, sizeof(*out));
    if (!out) {
        APP_ERROR("Memory allocation failed in concat_with_space");
        return NULL;
    }

    snprintf(out, len, "%s %s", a, b);

    return out;
}

static char *EscapeAndQuoteCmdArg(const char* arg)
{
    size_t arg_len = strlen(arg);
    size_t count = 0;
    for (size_t i = 0; i < arg_len; i++) { if (arg[i] == '\"') count++; }
    char *sanitized = calloc(1, arg_len + count * 2 + 3);
    if (!sanitized) {
        APP_ERROR("Failed to allocate memory");
        return NULL;
    }

    char *p = sanitized;
    *p++ = '\"';
    for (size_t i = 0; i < arg_len; i++) {
        if (arg[i] == '\"') { *p++ = '\\'; }
        *p++ = arg[i];
    }
    *p++ = '\"';
    *p = '\0';

    return sanitized;
}

static char *argv_to_command_line(char *argv[])
{
    size_t argc = 0;
    for (char **p = argv; *p; p++) argc++;

    char **quoted = calloc(argc + 1, sizeof(*quoted));
    if (!quoted) {
        APP_ERROR("Memory allocation failed in argv_to_command_line (quoted array)");
        return NULL;
    }
    quoted[argc] = NULL;

    size_t total_len = 0;
    for (size_t i = 0; i < argc; i++) {
        quoted[i] = EscapeAndQuoteCmdArg(argv[i]);
        if (!quoted[i]) {
            APP_ERROR("Failed to quote arg at index %zu", i);
            goto cleanup;
        }
        total_len += strlen(quoted[i]);
    }
    total_len += (argc > 0 ? argc - 1 : 0);

    char *command_line = calloc(total_len + 1, sizeof(*command_line));
    if (!command_line) {
        APP_ERROR("Memory allocation failed in argv_to_command_line (command_line)");
        goto cleanup;
    }

    char *dst = command_line;
    for (size_t i = 0; i < argc; i++) {
        if (i > 0) *dst++ = ' ';

        size_t len = strlen(quoted[i]);
        memcpy(dst, quoted[i], len);
        dst += len;
    }
    *dst = '\0';

    for (size_t i = 0; i < argc; i++) free(quoted[i]);
    free(quoted);
    return command_line;

cleanup:
    for (size_t j = 0; j < argc; j++) free(quoted[j]);
    free(quoted);
    return NULL;
}

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

static bool CreateAndWaitForProcess(const char *app_name, char *cmd_line, int *exit_code)
{
    PROCESS_INFORMATION pi = { 0 };
    STARTUPINFO         si = { .cb = sizeof(si) };
    bool result = false;

    DEBUG("ApplicationName=%s", app_name);
    DEBUG("CommandLine=%s", cmd_line);

    if (!CreateProcess(app_name, cmd_line, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        APP_ERROR("Failed to create process (%lu)", GetLastError());
        goto cleanup;
    }

    if (WaitForSingleObject(pi.hProcess, INFINITE) != WAIT_OBJECT_0) {
        APP_ERROR("Failed to wait script process (%lu)", GetLastError());
        goto cleanup;
    }

    if (!GetExitCodeProcess(pi.hProcess, (LPDWORD)exit_code)) {
        APP_ERROR("Failed to get exit status (%lu)", GetLastError());
        goto cleanup;
    }

    result = true;

cleanup:
    if (pi.hProcess && pi.hProcess != INVALID_HANDLE_VALUE) {
        CloseHandle(pi.hProcess);
    }
    if (pi.hThread && pi.hThread != INVALID_HANDLE_VALUE) {
        CloseHandle(pi.hThread);
    }
    return result;
}

bool RunScript(int argc, char *argv[], int *exit_code)
{
    if (!HAS_SCRIPT_INFO) {
        APP_ERROR("Script info is not initialized");
        return false;
    }

    char *extra_args = NULL;
    char *cmd_line = NULL;
    bool result = false;
    char *script_args = NULL;

    script_args = argv_to_command_line(ScriptARGV);
    if (!script_args) {
        APP_ERROR("Failed to build command line");
        goto cleanup;
    }

    if (argc > 1) {
        extra_args = argv_to_command_line(argv + 1);
    } else {
        extra_args = calloc(1, 1);
    }
    if (!extra_args) {
        APP_ERROR("Failed to build extra_args");
        goto cleanup;
    }

    cmd_line = concat_with_space(script_args, extra_args);
    if (!cmd_line) {
        APP_ERROR("Failed to build command line for script execution");
        goto cleanup;
    }

    result = CreateAndWaitForProcess(Script_ApplicationName, cmd_line, exit_code);

cleanup:
    free(extra_args);
    free(cmd_line);
    free(script_args);
    return result;
}
