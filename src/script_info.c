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

static char *argv_to_command_line(int argc, char *argv[])
{
    if (argc < 0) {
        APP_ERROR("Invalid argument count %d", argc);
        return NULL;
    }

    char **quoted = calloc((size_t)argc, sizeof(*quoted));
    if (!quoted) {
        APP_ERROR("Memory allocation failed in argv_to_command_line (quoted array)");
        return NULL;
    }

    size_t total_len = 0;
    for (int i = 0; i < argc; i++) {
        quoted[i] = EscapeAndQuoteCmdArg(argv[i]);
        if (!quoted[i]) {
            APP_ERROR("Failed to quote arg at index %d", i);
            goto cleanup;
        }
        total_len += strlen(quoted[i]);
    }
    total_len += (size_t)(argc > 0 ? argc - 1 : 0);

    char *command_line = calloc(total_len + 1, sizeof(*command_line));
    if (!command_line) {
        APP_ERROR("Memory allocation failed in argv_to_command_line (command_line)");
        goto cleanup;
    }

    char *p = command_line;
    for (int i = 0; i < argc; i++) {
        if (i > 0) *p++ = ' ';

        size_t len = strlen(quoted[i]);
        memcpy(p, quoted[i], len);
        p += len;
    }
    *p = '\0';

    for (int i = 0; i < argc; i++) free(quoted[i]);
    free(quoted);
    return command_line;

cleanup:
    for (int j = 0; j < argc; j++) free(quoted[j]);
    free(quoted);
    return NULL;
}

static char **transform_argv(int argc, const char *argv[])
{
    if (argc <= 0) {
        APP_ERROR("No arguments to transform");
        return NULL;
    }

    char **out_argv = calloc((size_t)argc + 1, sizeof(*out_argv));
    if (!out_argv) {
        APP_ERROR("Memory allocation failed in transform_argv");
        return NULL;
    }

    for (int i = 0; i < argc; i++) {
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
    for (int j = 0; j < argc; j++) free(out_argv[j]);
    free(out_argv);
    return NULL;
}

static bool ParseArguments(const char *args, size_t args_size, size_t *out_argc, const char ***out_argv)
{
    size_t local_argc = 0;
    for (const char *s = args; s < (args + args_size); s += strlen(s) + 1) {
        local_argc++;
    }

    const char **local_argv = calloc(local_argc + 1, sizeof(local_argv[0]));
    if (!local_argv) {
        APP_ERROR("Failed to memory allocate for argv");
        return false;
    }

    const char *s = args;
    for (size_t i = 0; i < local_argc; i++) {
        local_argv[i] = s;
        s += strlen(s) + 1;
    }
    local_argv[local_argc] = NULL;

    *out_argc = local_argc;
    *out_argv = local_argv;
    return true;
}

static char *Script_ApplicationName = NULL;
static char *Script_CommandLine = NULL;

#define HAS_SCRIPT_INFO (Script_ApplicationName && Script_CommandLine)

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
    char *command_line = NULL;
    size_t argc;
    const char **argv = NULL;
    char **t_arg = NULL;
    bool result = false;

    if (!ParseArguments(args, args_size, &argc, &argv)) {
        APP_ERROR("Failed to parse arguments");
        goto cleanup;
    }

    if (!IsPathFreeOfDotElements(argv[0])) {
        APP_ERROR("Application name contains prohibited relative path elements like '.' or '..'");
        goto cleanup;
    }

    if (!IsPathFreeOfDotElements(argv[1])) {
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
    t_arg = transform_argv((int)argc, argv);
    if (!t_arg) {
        APP_ERROR("Failed to transform argv");
        goto cleanup;
    }

    command_line = argv_to_command_line((int)argc, t_arg);
    if (!command_line) {
        APP_ERROR("Failed to build command line");
        goto cleanup;
    }

    Script_ApplicationName = application_name;
    Script_CommandLine = command_line;
    result = true;

cleanup:
    if (!result) {
        free(application_name);
        free(command_line);
    }
    free(argv);
    if (t_arg) {
        for (int i = 0; i < argc; i++) free(t_arg[i]);
    }
    free(t_arg);
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

    if (!CreateProcess(app_name, cmd_line, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        APP_ERROR("Failed to create process (%lu)", GetLastError());
        *exit_code = (int)GetLastError();
        goto cleanup;
    }

    if (WaitForSingleObject(pi.hProcess, INFINITE) != WAIT_OBJECT_0) {
        APP_ERROR("Failed to wait script process (%lu)", GetLastError());
        *exit_code = (int)GetLastError();
        goto cleanup;
    }

    if (!GetExitCodeProcess(pi.hProcess, (LPDWORD)exit_code)) {
        APP_ERROR("Failed to get exit status (%lu)", GetLastError());
        *exit_code = (int)GetLastError();
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

    if (argc > 1) {
        extra_args = argv_to_command_line(argc - 1, argv + 1);
    } else {
        extra_args = calloc(1, 1);
    }
    if (!extra_args) {
        APP_ERROR("Failed to build extra_args");
        goto cleanup;
    }

    cmd_line = concat_with_space(Script_CommandLine, extra_args);
    if (!cmd_line) {
        APP_ERROR("Failed to build command line for script execution");
        goto cleanup;
    }

    result = CreateAndWaitForProcess(Script_ApplicationName, cmd_line, exit_code);

cleanup:
    free(extra_args);
    free(cmd_line);
    return result;
}
