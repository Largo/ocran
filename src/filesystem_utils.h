#include <windows.h>

#ifdef _WIN32
#define PATH_SEPARATOR '\\'
#else
#define PATH_SEPARATOR '/'
#endif

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
 * CreateDirectoriesRecursively - Creates a directory and all its parent directories if they do not exist.
 *
 * @param dir The path of the directory to create.
 * @return TRUE if the directory was successfully created or already exists.
 *         FALSE if the directory could not be created due to an error.
 */
BOOL CreateDirectoriesRecursively(const char *dir);

/**
 * CreateParentDirectories - Creates all parent directories of the specified file path.
 *
 * @param file The path of the file whose parent directories need to be created.
 * @return TRUE if the parent directories were successfully created or already exist.
 *         FALSE if the directories could not be created due to an error.
 */
BOOL CreateParentDirectories(const char *file);

/**
 * DeleteRecursively - Deletes a directory and all its contents recursively.
 *
 * @param path The path of the directory to delete.
 * @return TRUE if the directory and its contents were successfully deleted.
 *         FALSE if the directory could not be fully deleted due to an error.
 */
BOOL DeleteRecursively(const char *path);

// Defines the length of the unique identifier used in the directory name.
#define UID_LENGTH 12
// Defines the maximum number of attempts to create a unique directory.
#define MAX_RETRY_CREATE_UNIQUE_DIR (unsigned int)20

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
 * GetImageDirectoryPath - Retrieves the directory path of the executable file of the current process.
 *
 * @return A pointer to a newly allocated string that represents the directory path of the executable.
 *         Returns NULL if the path could not be retrieved or if memory allocation fails.
 */
char *GetImageDirectoryPath(void);

/**
 * GetTempDirectoryPath - Retrieves the path of the temporary directory for the current user.
 *
 * @return A pointer to a newly allocated string that represents the path of the temporary directory.
 *         Returns NULL if the path could not be retrieved or if memory allocation fails.
 */
char *GetTempDirectoryPath(void);

/**
 * Checks if the given path string is free of relative path elements.
 *
 * This function examines the string to ensure that it does not contain
 * relative path elements, specifically '.' and '..' segments.
 * It's useful for validating paths that should not refer to any relative
 * locations, especially when dealing with file system navigation.
 *
 * @param str The path string to be checked.
 * @return TRUE if the path does not contain relative path elements, otherwise FALSE.
 */
BOOL IsPathFreeOfDotElements(const char *str);

/**
 * ChangeDirectoryToSafeDirectory - Change the current working directory to a predefined safe directory.
 *
 * This function is used to switch the current working directory to a safe location, typically
 * used to prevent any operations that could interfere with user data or system operations.
 * This is particularly useful during cleanup operations or when the application needs to
 * ensure it operates in a controlled environment.
 *
 * @return BOOL Returns TRUE if the directory change was successful, otherwise FALSE.
 */
BOOL ChangeDirectoryToSafeDirectory(void);

typedef const void *MappedFile;

/**
 * OpenAndMapFile - Opens a file and maps it into memory as read-only.
 *
 * This function opens the specified file in read-only mode and maps its entire
 * content into memory with read-only access. It returns a handle that encapsulates
 * the file handle, the mapping handle, and the base address of the mapped content.
 * The content mapped into memory is guaranteed to be read-only, ensuring data integrity.
 *
 * @param file_path The path of the file to be opened and mapped.
 * @param file_size A pointer to a variable where the size of the file will be
 *                  stored. If the pointer is NULL, the file size is not returned.
 * @param mapped_base A pointer to a pointer variable that will receive the base
 *                    address of the mapped file. The address pointed to by this
 *                    pointer is read-only. If the pointer is NULL, the base
 *                    address is not returned.
 * @return A MappedFile handle that must be freed with FreeMappedFile when no
 *         longer needed. Returns NULL if the operation fails.
 *
 * On failure, the function logs an error and cleans
 * up any opened resources before returning NULL.
 */
MappedFile OpenAndMapFile(const char *file_path, unsigned long long *file_size, const void **mapped_base);

/**
 * FreeMappedFile - Frees a MappedFile handle and its associated resources.
 *
 * This function unmaps the mapped view of the file, closes the mapping and
 * file handles, and frees the memory used by the MappedFileHandle structure.
 * It is intended to be used to clean up resources allocated by OpenAndMapFile.
 *
 * @param handle The MappedFile handle to free. This handle should have been
 *               obtained from OpenAndMapFile.
 * @return TRUE if all resources were successfully released; otherwise, FALSE.
 *
 * If the function fails to release any resources, it logs an error
 * for each failure. However, it attempts to free all resources
 * regardless of individual errors.
 */
BOOL FreeMappedFile(MappedFile handle);
