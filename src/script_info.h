#include <stdbool.h>
#include <stddef.h>

bool GetScriptInfo(const char **app_name, char **cmd_line);
bool SetScriptInfo(const char *info, size_t info_size);
void FreeScriptInfo(void);
bool RunScript(char *argv[], int *exit_code);
