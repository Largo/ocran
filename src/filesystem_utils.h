#include <windows.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef _WIN32
#define PATH_SEPARATOR '\\'
#else
#define PATH_SEPARATOR '/'
#endif

static inline bool is_path_separator(char c) {
#ifdef _WIN32
    return c == '\\' || c == '/';
#else
    return c == '/';
#endif
}

/**
 * @brief   Check if a path is a “clean” relative path.
 *
 * A clean relative path satisfies all of the following:
 *   - Non-NULL, non-empty (`path != NULL && *path != '\0'`)
 *   - Does not start with a path separator (`'/'` or `'\'`)
 *   - On Windows, does not use a drive-letter specifier (e.g. `"C:\"`)
 *   - Contains no empty segments (no `"//"` or `"\\"`)
 *   - Contains no `"."` or `".."` segments
 *
 * @param   path  A null-terminated string representing the path to validate.
 * @return  true  if the input meets all clean-relative-path criteria;  
 *          false otherwise.
 */
bool IsCleanRelativePath(const char *path);

/**
 * JoinPath - Combines two file path components into a single path.
 *
 * @param p1 The first path component.
 * @param p2 The second path component.
 * @return A pointer to a newly allocated string that represents the combined file path.
 *         Returns NULL if either input is NULL, empty, or if memory allocation fails.
 */
char *JoinPath(const char *p1, const char *p2);

/**
 * @brief  Returns a newly allocated string containing the parent
 *         directory for a given path.
 * @param  path  Input path (must be non-NULL).
 * @return
 *   - NULL       if path is NULL or on allocation failure.
 *   - ""         if path is empty or has no parent segment.
 *   - otherwise  malloc’d NUL-terminated parent path (caller must free).
 */
char *GetParentPath(const char *path);

/**
 * CreateDirectoriesRecursively - Creates a directory and all its parent directories if they do not exist.
 *
 * @param dir The path of the directory to create.
 * @return true if the directory was successfully created or already exists.
 *         false if the directory could not be created due to an error.
 */
bool CreateDirectoriesRecursively(const char *dir);

/**
 * DeleteRecursively - Deletes a directory and all its contents recursively.
 *
 * @param path The path of the directory to delete.
 * @return true if the directory and its contents were successfully deleted.
 *         false if the directory could not be fully deleted due to an error.
 */
bool DeleteRecursively(const char *path);

// Defines the length of the unique identifier used in the directory name.
#define UID_LENGTH 12
// Defines the maximum number of attempts to create a unique directory.
#define MAX_RETRY_CREATE_UNIQUE_DIR 20U

/**
 * CreateUniqueDirectory - Creates a unique directory within a base path, using a specified prefix for the directory name.
 * This function attempts to generate a directory name that does not already exist by appending a unique identifier
 * to the provided prefix. The unique identifier is generated based on a performance counter and has a fixed length.
 *
 * @param base_path The base path where the unique directory will be created.
 * @param prefix The prefix to use for the directory name. The final directory name will be formed by concatenating
 *               this prefix with a unique identifier.
 * @return A pointer to a newly allocated string that represents the full path of the created directory.
 *         Returns NULL if the directory could not be created due to an error or if all attempts fail.
 */
char *CreateUniqueDirectory(const char *base_path, const char *prefix);

/**
 * GetImagePath - Retrieves the full path of the executable file of the current process.
 *
 * @return A pointer to a newly allocated string that represents the full path of the executable.
 *         Returns NULL if the path could not be retrieved or if memory allocation fails.
 */
char *GetImagePath(void);

/**
 * GetTempDirectoryPath - Retrieves the path of the temporary directory for the current user.
 *
 * @return A pointer to a newly allocated string that represents the path of the temporary directory.
 *         Returns NULL if the path could not be retrieved or if memory allocation fails.
 */
char *GetTempDirectoryPath(void);

/**
 * @brief Changes the current working directory to the specified path.
 * 
 * @param path The path to set as the current working directory.
 *             Must be a valid directory path.
 * @return true if the operation succeeds, false otherwise.
 *         Logs an error message if the operation fails.
 */
bool ChangeWorkingDirectory(const char* path);

/**
 * @brief Writes the contents of a buffer to the specified file path.
 *        Creates any missing parent directories and overwrites existing files.
 *
 * @param path        Output file path (absolute or relative).
 * @param buffer      Pointer to the data buffer to write.
 * @param buffer_size Size of the data buffer in bytes.
 * @return            true if the write succeeded, false otherwise.
 */
bool ExportFile(const char *path, const void *buffer, size_t buffer_size);

/**
 * @brief Opaque handle to a memory-mapped file region.
 *
 * The contents of this structure are private; users must
 * obtain and destroy instances via the API functions below.
 */
typedef struct MemoryMap MemoryMap;

/**
 * @brief Creates a memory map for the entire contents of a file.
 *
 * Opens @p path in read-only mode and maps its full length
 * into memory.  The returned pointer must later be passed to
 * DestroyMemoryMap() to unmap and free resources.
 *
 * @param path        Path to an existing file to map; must not be NULL.
 * @return            Pointer to a new MemoryMap on success, or NULL on failure.
 */
MemoryMap *CreateMemoryMap(const char *path);

/**
 * @brief Unmaps and destroys a MemoryMap object.
 *
 * Releases the mapped view and frees all associated resources.
 * After this call, @p map is no longer valid.  Passing NULL
 * will log an error but otherwise do nothing.
 *
 * @param map         MemoryMap instance to destroy.
 */
void DestroyMemoryMap(MemoryMap *map);

/**
 * @brief Returns the base address of the mapped view.
 *
 * @param map         A valid MemoryMap returned by CreateMemoryMap.
 *                    Must not be NULL.
 * @return            Base address of the mapping, or NULL if @p map is NULL.
 */
void *GetMemoryMapBase(const MemoryMap *map);

/**
 * @brief Returns the size of the mapped region in bytes.
 *
 * @param map         A valid MemoryMap returned by CreateMemoryMap.
 *                    Must not be NULL.
 * @return            Size in bytes of the mapping, or 0 if @p map is NULL.
 *                    Note: 0 may also be a valid size for an empty file.
 */
size_t GetMemoryMapSize(const MemoryMap *map);

/**
 * @brief Initialize signal and control handling.
 *
 * This function sets up console control and POSIX signal handlers so that
 * the parent process is not prematurely terminated during initialization and
 * cleanup phases. On Windows, a console control handler is registered to ignore
 * control events (e.g., Ctrl+C) in the parent process. On POSIX, relevant
 * signals (SIGINT, SIGTERM, SIGHUP) can be configured to allow cleanup
 * processing before exit.
 *
 * @return
 *   - true  if initialization succeeded  
 *   - false if an error occurred (e.g., SetConsoleCtrlHandler failed)
 */
bool InitializeSignalHandling(void);

/**
 * @brief Sets or removes an environment variable.
 *
 * Sets the specified environment variable to the given value. If value is NULL,
 * the variable will be removed from the environment. Returns true on success,
 * false if the operation fails.
 *
 * @param name  Name of the environment variable to set or remove.
 * @param value Value to assign to the variable, or NULL to remove it.
 * @return true if the operation succeeded; false otherwise.
 */
bool SetEnvVar(const char *name, const char *value);

/**
 * @brief Launches the specified application with given arguments,
 *        waits for it to finish, and retrieves its exit code.
 *
 * @param app_name
 *   Path of the executable to run.
 * @param argv
 *   NULL-terminated array of argument strings; each element is one argument.
 * @param exit_code
 *   Pointer to an int where the child process’s exit code will be stored.
 * @return
 *   True if the process was successfully created, waited on, and its exit
 *   code retrieved; false otherwise.
 */
bool CreateAndWaitForProcess(const char *app_name, char *argv[], int *exit_code);
