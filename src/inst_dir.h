#include <windows.h>
#include <stdbool.h>

/**
 * @brief Creates an installation directory with a unique name.
 *
 * Attempts to create a directory within the specified target directory. This
 * directory is assigned a unique name based on the "ocran" prefix to avoid
 * conflicts. The function manages the lifetime of the created directory path's
 * memory, which should not be freed by the caller.
 * If directory cleanup is needed, call FreeInstDir().
 *
 * @param is_extract_to_exe_dir
 *   If true, the extraction directory will be created in the same folder as
 *   the executable; if false, it will be created in the system’s temporary
 *   directory.
 * @return
 *   A pointer to the created directory path if successful, NULL if an error
 *   occurred. The returned path should not be freed by the caller.
 */
const char *CreateInstDir(bool is_extract_to_exe_dir);

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
 * ExpandInstDirPath - Concatenates the installation directory path with a given
 * relative path.
 *
 * This function guarantees that the resulting path will not escape the
 * installation directory. It will fail and return NULL if any of the following
 * conditions are met:
 *   - the installation directory (InstDir) is not set or is empty
 *   - rel_path is NULL or empty
 *   - rel_path contains prohibited path elements such as "." or "..", including
 *     patterns like "/./" or "/../"
 *
 * @param rel_path
 *   A relative path to be combined with the installation directory path.
 *   Must not be absolute, must not be empty, and must not contain any "." or
 *   ".." segments (e.g., "/./", "/../", "./", "../").
 *
 * @return
 *   A newly allocated string representing the full path on success; NULL on
 *   error (and an appropriate error message is logged).
 */
char *ExpandInstDirPath(const char *rel_path);

/**
 * DeleteInstDir - Deletes the installation directory and its contents.
 *
 * @return true if the directory and its contents were deleted successfully,
 *         false otherwise.
 */
bool DeleteInstDir(void);

// Placeholder character used in paths.
#define PLACEHOLDER '|'

/**
 * @brief Replace placeholders in a template string
 *        with the installation directory path.
 *
 * @param tmpl
 *   The template string containing placeholder characters defined by the
 *   PLACEHOLDER macro, which will be replaced by the installation directory
 *   path.
 * @return
 *   A newly allocated string with all PLACEHOLDER occurrences replaced by the
 *   installation directory path. Returns NULL on failure.
 */
char *ReplaceInstDirPlaceholder(const char *tmpl);

/**
 * @brief   Retrieve the working directory to use when spawning the
 *           script process.
 *
 * This function builds and returns a null-terminated string representing
 * the filesystem path that the stub will switch to before launching the
 * child process running the Ruby script. The caller is responsible for
 * freeing the returned string with free() when it is no longer needed.
 *
 * @return  Pointer to a null-terminated path string on success,
 *          or NULL on failure.
 */
char *GetScriptWorkingDirectoryPath(void);

/**
 * ChangeDirectoryToScriptDirectory - Change the current working directory to the script's directory.
 *
 * This function attempts to change the process's current working directory to the directory
 * where the script is located. This is typically used to ensure that relative paths
 * in script operations resolve correctly.
 *
 * @return bool Returns true if the directory change was successful, otherwise false.
 */
bool ChangeDirectoryToScriptDirectory(void);

/**
 * ChangeDirectoryToSafeDirectory - Change the current working directory to a predefined safe directory.
 *
 * This function is used to switch the current working directory to a safe location, typically
 * used to prevent any operations that could interfere with user data or system operations.
 * This is particularly useful during cleanup operations or when the application needs to
 * ensure it operates in a controlled environment.
 *
 * @return bool Returns true if the directory change was successful, otherwise false.
 */
bool ChangeDirectoryToSafeDirectory(void);

/**
 * CreateDirectoryUnderInstDir - Recursively create a directory under the
 * installation directory.
 *
 * This function ensures that a directory exists at the specified relative
 * path under the installation directory. An empty rel_path is treated as
 * already existing (returns true). If rel_path is NULL, ExpandInstDirPath
 * fails, or directory creation fails, the function returns false and logs
 * an error.
 *
 * @param rel_path
 *   A relative path to a directory under the installation directory.
 *   NULL is invalid (returns false). An empty string is treated as
 *   already existing (returns true).
 *
 * @return
 *   true if the directory already exists or was created successfully;
 *   false on error (and an error is logged).
 */
bool CreateDirectoryUnderInstDir(const char *rel_path);

/**
 * ExportFileToInstDir - Atomically write a file under the installation dir.
 *
 * This function writes the given buffer as a file at the specified
 * relative path under the installation directory. It validates rel_path
 * and buf, expands the full path, creates any missing parent directories,
 * and writes the data atomically. If len is zero, an empty file is
 * created.
 *
 * @param rel_path
 *   A relative file path under the installation directory. NULL or empty
 *   string is invalid (returns false).
 * @param buf
 *   Pointer to the data to write. Must be non-NULL if len > 0.
 * @param len
 *   Number of bytes to write. Zero creates an empty file. Values above
 *   MAXDWORD cause an error.
 *
 * @return
 *   true on success; false on failure (error logged via APP_ERROR/DEBUG).
 */
bool ExportFileToInstDir(const char *rel_path, const void *buf, size_t len);

/**
 * @brief  Expands any installation-directory placeholder found in 'value' and
 *         sets the environment variable.
 *
 * @param  name   Environment variable name to set (must not be NULL).
 * @param  value  Value string that may include a placeholder for the
 *                installation directory.
 *
 * @return true on success; false on failure.
 */
bool SetEnvWithInstDir(const char *name, const char *value);
