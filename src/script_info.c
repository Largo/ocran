#include <windows.h>
#include <string.h>
#include "error.h"
#include "filesystem_utils.h"
#include "inst_dir.h"

static char* ConcatStr(const char *first, ...) {
    va_list args;
    va_start(args, first);
    size_t len = 0;
    for (const char* s = first; s; s = va_arg(args, const char*)) {
        len += strlen(s);
    }
    va_end(args);

    char *str = (char *)calloc(1, len + 1);
    if (!str) {
        APP_ERROR("Failed to allocate memory");
        return NULL;
    }

    va_start(args, first);
    char *p = str;
    for (const char *s = first; s; s = va_arg(args, const char*)) {
        size_t l = strlen(s);
        memcpy(p, s, l);
        p += l;
    }
    str[len] = '\0';
    va_end(args);

    return str;
}

#define CONCAT_STR3(s1, s2, s3) ConcatStr(s1, s2, s3, NULL)

static char *EscapeAndQuoteCmdArg(const char* arg)
{
    size_t arg_len = strlen(arg);
    size_t count = 0;
    for (size_t i = 0; i < arg_len; i++) { if (arg[i] == '\"') count++; }
    char *sanitized = (char *)calloc(1, arg_len + count * 2 + 3);
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

static bool ParseArguments(const char *args, size_t args_size, size_t *out_argc, const char ***out_argv)
{
    size_t local_argc = 0;
    for (const char *s = args; s < (args + args_size); s += strlen(s) + 1) {
        local_argc++;
    }

    const char **local_argv = (const char **)calloc(1, (local_argc + 1) * sizeof(char *));
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

static char *BuildCommandLine(size_t argc, const char *argv[])
{
    char *command_line = EscapeAndQuoteCmdArg(argv[0]);
    if (command_line == NULL) {
        APP_ERROR("Failed to initialize command line with first arg");
        return NULL;
    }

    for (size_t i = 1; i < argc; i++) {
        char *str;
        if (i == 1) {
            str = ExpandInstDirPath(argv[1]);
            if (str == NULL) {
                APP_ERROR("Failed to expand script name to installation directory at arg index 1");
                goto cleanup;
            }
        } else {
            str = ReplaceInstDirPlaceholder(argv[i]);
            if (str == NULL) {
                APP_ERROR("Failed to replace arg placeholder at arg index %d", i);
                goto cleanup;
            }
        }

        char *sanitized = EscapeAndQuoteCmdArg(str);
        free(str);
        if (sanitized == NULL) {
            APP_ERROR("Failed to sanitize arg at arg index %d", i);
            goto cleanup;
        }
        char *base = command_line;
        command_line = CONCAT_STR3(base, " ", sanitized);
        free(base);
        free(sanitized);
        if (command_line == NULL) {
            APP_ERROR("Failed to build command line after adding arg at arg index %d", i);
            goto cleanup;
        }
    }

    return command_line;

cleanup:
    free(command_line);

    return NULL;
}

static const char *Script_ApplicationName = NULL;
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

    size_t argc;
    const char **argv = NULL;
    if (!ParseArguments(args, args_size, &argc, &argv)) {
        APP_ERROR("Failed to parse arguments");
        return false;
    }

    if (!IsPathFreeOfDotElements(argv[0])) {
        APP_ERROR("Application name contains prohibited relative path elements like '.' or '..'");
        return false;
    }

    if (!IsPathFreeOfDotElements(argv[1])) {
        APP_ERROR("Script name contains prohibited relative path elements like '.' or '..'");
        return false;
    }

    // Set Script_ApplicationName
    char *application_name = ExpandInstDirPath(argv[0]);
    if (application_name == NULL) {
        APP_ERROR("Failed to expand application name to installation directory");
        free(argv);
        return false;
    }

    // Set Script_CommandLine
    char *command_line = BuildCommandLine(argc, argv);
    if (command_line == NULL) {
        APP_ERROR("Failed to build command line");
        free(argv);
        return false;
    }

    free(argv);

    Script_ApplicationName = application_name;
    Script_CommandLine = command_line;

    return true;
}

void FreeScriptInfo(void)
{
    free((char *)Script_ApplicationName);
    Script_ApplicationName = NULL;

    free(Script_CommandLine);
    Script_CommandLine = NULL;
}

bool CreateAndWaitForProcess(const char *app_name, char *cmd_line, DWORD *exit_code)
{
    PROCESS_INFORMATION p_info;
    ZeroMemory(&p_info, sizeof(p_info));
    STARTUPINFO s_info;
    ZeroMemory(&s_info, sizeof(s_info));
    s_info.cb = sizeof(s_info);
    bool result = false;

    if (CreateProcess(app_name, cmd_line, NULL, NULL, TRUE, 0, NULL, NULL, &s_info, &p_info)) {
        if (WaitForSingleObject(p_info.hProcess, INFINITE) != WAIT_FAILED) {
            if (GetExitCodeProcess(p_info.hProcess, exit_code)) {
                result = true;
            } else {
                APP_ERROR("Failed to get exit status (%lu)", GetLastError());
                *exit_code = GetLastError();
            }
        } else {
            APP_ERROR("Failed to wait script process (%lu)", GetLastError());
            *exit_code = GetLastError();
        }
        CloseHandle(p_info.hProcess);
        CloseHandle(p_info.hThread);
    } else {
        APP_ERROR("Failed to create process (%lu)", GetLastError());
        *exit_code = GetLastError();
    }

    return result;
}

bool RunScript(const char *extra_args, DWORD *exit_code)
{
    if (!HAS_SCRIPT_INFO) {
        APP_ERROR("Script info is not initialized");
        return false;
    }

    char *cmd_line = CONCAT_STR3(Script_CommandLine, " ", extra_args);
    if (cmd_line == NULL) {
        APP_ERROR("Failed to build command line for script execution");
        return false;
    }

    bool result = CreateAndWaitForProcess(Script_ApplicationName, cmd_line, exit_code);

    free(cmd_line);
    return result;
}
