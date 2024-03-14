#include <windows.h>

BOOL GetScriptInfo(const char **app_name, char **cmd_line);
BOOL InitializeScriptInfo(const char *args, size_t args_size);
void FreeScriptInfo(void);
BOOL RunScript(const char *extra_args, DWORD *exit_code);
