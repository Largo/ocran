#include <stdbool.h>
#include <stddef.h>

bool IsScriptInfoSet(void);
bool SetScriptInfo(const char *info, size_t info_size);
void FreeScriptInfo(void);
bool WriteScriptInfoFile(void);
bool LaunchLauncher(char *argv[], int *exit_code);
