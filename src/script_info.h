#include <stdbool.h>
#include <stddef.h>

char **GetScriptInfo(void);
bool SetScriptInfo(const char *info, size_t info_size);
void FreeScriptInfo(void);
/**
 * Launches the packaged script.
 *
 * @param argv                    Original argv of the stub; elements after
 *                                argv[0] are appended to the script arguments.
 * @param is_chdir_to_script_dir  When true, the script starts with its working
 *                                directory set to the extracted script's
 *                                directory (--chdir-first).
 * @param chdir_dir               When non-NULL (and is_chdir_to_script_dir is
 *                                false), the script starts with its working
 *                                directory set to this path (--chdir-exe-dir).
 * @param exit_code               Receives the script's exit code.
 */
bool RunScript(char *argv[], bool is_chdir_to_script_dir,
               const char *chdir_dir, int *exit_code);
