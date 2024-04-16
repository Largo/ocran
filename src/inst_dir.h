#include <windows.h>

/**
 * CreateInstDirectory - Creates an installation directory with a unique name in the specified target directory.
 *
 * Attempts to create a directory within the specified target directory. This directory is assigned a unique name
 * based on the "ocran" prefix to avoid conflicts. The function manages the lifetime of the created directory path's
 * memory, which should not be freed by the caller. If directory cleanup is needed, call FreeInstDir().
 *
 * @param target_dir The target directory where the installation directory will be created.
 * @return const char* A pointer to the created directory path if successful, NULL if an error occurred. The returned
 * path should not be freed by the caller.
 */
const char *CreateInstDirectory(const char *target_dir);

/**
 * CreateDebugExtractInstDir - Creates a debug installation directory next to the executable.
 *
 * Attempts to create a directory for debug purposes in the same location as the executable file. This directory
 * is intended for use during development and testing, allowing for easier access to and management of debug files.
 * The function returns a const pointer to the directory path if successful, or NULL if an error occurred.
 * The caller should not free the returned pointer; if directory cleanup is needed, call FreeInstDir().
 *
 * @return const char* A pointer to the created directory path if successful, NULL if an error occurred.
 */
const char *CreateDebugExtractInstDir(void);

/**
 * CreateTemporaryInstDir - Creates a temporary installation directory in the system's temp directory.
 *
 * Creates a unique directory within the system's temporary directory. This is used for operations that require
 * a temporary workspace that can be cleaned up after use. It's particularly useful for applications that need
 * to extract and process files without leaving a permanent footprint on the host system.
 * The function returns a const pointer to the directory path if successful, or NULL if an error occurred.
 * The caller should not free the returned pointer; if directory cleanup is needed, call FreeInstDir().
 *
 * @return const char* A pointer to the created directory path if successful, NULL if an error occurred.
 */
const char *CreateTemporaryInstDir(void);

/**
 * FreeInstDir - Frees the allocated memory for the installation directory path and resets the pointer to NULL.
 */
void FreeInstDir(void);

/**
 * GetInstDir - Returns the path to the installation directory.
 *
 * @return A pointer to the installation directory path if set, NULL otherwise.
 */
const char *GetInstDir(void);

/**
 * ExpandInstDirPath - Concatenates the installation directory path with a given relative path.
 *
 * @param rel_path A relative path to be combined with the installation directory path.
 * @return A pointer to a newly allocated string representing the full path if successful, NULL otherwise.
 */
char *ExpandInstDirPath(const char *rel_path);

/**
 * CheckInstDirPathExists - Checks the existence of a file or directory within the installation directory.
 *
 * @param rel_path A relative path within the installation directory to check for existence.
 * @return TRUE if the path exists, FALSE otherwise.
 */
BOOL CheckInstDirPathExists(const char *rel_path);

/**
 * DeleteInstDirRecursively - Deletes the installation directory and all its contents recursively.
 *
 * @return TRUE on successful deletion, FALSE on failure.
 */
BOOL DeleteInstDirRecursively(void);

// Suffix for the deletion marker file.
#define DELETION_MAKER_SUFFIX ".ocran-delete-me"

/**
 * MarkInstDirForDeletion - Creates a marker file indicating the directory is to be deleted.
 */
void MarkInstDirForDeletion(void);

// Placeholder character used in paths.
#define PLACEHOLDER '|'

/**
 * ReplaceInstDirPlaceholder - Replaces placeholders in a string with the installation directory path.
 *
 * @param str The string containing placeholders to be replaced with the installation directory path.
 * @return A new string with placeholders replaced by the installation directory path, NULL on failure.
 */
char *ReplaceInstDirPlaceholder(const char *str);

/**
 * ChangeDirectoryToScriptDirectory - Change the current working directory to the script's directory.
 *
 * This function attempts to change the process's current working directory to the directory
 * where the script is located. This is typically used to ensure that relative paths
 * in script operations resolve correctly.
 *
 * @return BOOL Returns TRUE if the directory change was successful, otherwise FALSE.
 */
BOOL ChangeDirectoryToScriptDirectory(void);
