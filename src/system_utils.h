#ifdef _WIN32
#include <windows.h>
#endif
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

/* Length of the root prefix of an absolute path ("/", or "C:\" on
   Windows), which a parent path never loses; 0 for a relative path. */
static inline size_t path_root_length(const char *path) {
#ifdef _WIN32
    if (((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z'))
        && path[1] == ':' && is_path_separator(path[2])) {
        return 3;
    }
#endif
    return is_path_separator(path[0]) ? 1 : 0;
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

/**
 * @brief Windows-side replacement for POSIX mkdtemp().
 *
 * The string \t tmpl must end with at least six ’X’ characters.
 * Those X’s are replaced with random portable-filename characters and
 * the function tries to create the directory.  
 *
 * @param tmpl  Writable, NUL-terminated buffer ending in “XXXXXX”.
 * @return      tmpl on success (now holding the new path), or NULL on error
 *              with errno set.
 */
char *CreateUniqueDirectory(char *tmpl);

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
 * @brief Normalizes a path to its long form.
 *
 * On Windows, converts 8.3 short names (e.g. "C:\\Users\\RUNNER~1") to the
 * full long path via GetLongPathName. Two spellings of the same directory
 * would otherwise defeat Ruby's $LOADED_FEATURES deduplication, causing
 * files to be loaded twice ("already initialized constant" warnings).
 * On POSIX this simply returns a copy of the given path.
 *
 * @return A newly allocated string (caller frees), or NULL on allocation
 *         failure. Falls back to a copy of the input if conversion fails.
 */
char *ToLongPath(const char *path);

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
 * control events (e.g., Ctrl+C) in the parent process. On POSIX, SIGINT,
 * SIGTERM, SIGHUP and SIGQUIT are caught and forwarded to the child once it
 * runs, so the stub outlives it and can clean up.
 *
 * @return
 *   - true  if initialization succeeded  
 *   - false if an error occurred (e.g., SetConsoleCtrlHandler failed)
 */
bool InitializeSignalHandling(void);

/**
 * @brief Registers the routine that deletes the extraction directory.
 *
 * The routine runs at most once, through RunCleanupRoutine(): at the end of
 * main(), or on Windows from the console control handler when Windows is
 * about to terminate the stub (console window closed, system shutdown),
 * once the child has exited or been ended. It must therefore cope with
 * being called at any point of main().
 */
void SetCleanupRoutine(void (*routine)(void));

/**
 * @brief Runs the registered cleanup routine unless it has run already.
 *
 * If another thread is running it at the time, waits until it is done.
 */
void RunCleanupRoutine(void);

/**
 * @brief Dies of the signal that killed the child, if one did.
 *
 * On POSIX, when the child launched by CreateAndWaitForProcess was killed by
 * a signal, or a termination signal arrived before it could be started, the
 * stub re-raises that signal with its default action so that its own parent
 * sees the same kind of death. Call it after cleanup. Returns if there is no
 * such signal, or if the process survives it (e.g. PID 1 in a container);
 * the caller then exits with 128 + signal as reported in exit_code.
 * No-op on Windows.
 */
void ReraiseChildSignal(void);

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
