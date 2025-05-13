#include <windows.h>
#include <stdbool.h>

bool GetScriptInfo(const char **app_name, char **cmd_line);
bool InitializeScriptInfo(const char *args, size_t args_size);
void FreeScriptInfo(void);
bool RunScript(const char *extra_args, DWORD *exit_code);
