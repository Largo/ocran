#include <windows.h>

BOOL GetScriptInfo(const char **app_name, char **cmd_line);
BOOL InitializeScriptInfo(const char *args, size_t args_size, char *extra_args);
void FreeScriptInfo(void);
