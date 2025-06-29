#include <stdbool.h>
#include <stddef.h>

char **GetScriptInfo(void);
bool SetScriptInfo(const char *info, size_t info_size);
void FreeScriptInfo(void);
bool RunScript(char *argv[], bool is_chdir_to_script_dir, int *exit_code);
