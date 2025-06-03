#include <windows.h>
#include <stdbool.h>
#include "error.h"
#include "filesystem_utils.h"

/*
 * Returns true if `path` is a “clean” relative path:
 * - not empty
 * - does not start with a path separator
 * - on Windows, no drive-letter spec (e.g. "C:\")
 * - no empty segments ("//")
 * - no "." or ".." segments
 */
bool IsCleanRelativePath(const char *path)
{
    if (!path || !*path) {
        return false;
    }  

#ifdef _WIN32
    /* Forbid Windows drive specification (e.g. "C:\") */
    if (((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z'))
        && path[1] == ':'
        && is_path_separator(path[2])) {
        return false;
    }
#endif

    /* Forbid absolute path (leading '/' or '\') */
    if (is_path_separator(*path)) {
        return false;
    }

    /* Validate each path segment */
    const char *p = path;
    while (*p) {
        const char *start = p;

        /* Advance until next separator or end-of-string */
        while (*p && !is_path_separator(*p)) {
            p++;
        }

        size_t len = p - start;

        /* Reject empty, "." or ".." segments */
        if (len == 0
            || (len == 1 && start[0] == '.')
            || (len == 2 && start[0] == '.' && start[1] == '.')) {
            return false;
        }

        /* Skip over the separator */
        if (*p) {
            p++;
        }
    }

    return true;
}

// Combines two file path components into a single path, handling path separators.
char *JoinPath(const char *p1, const char *p2)
{
    if (p1 == NULL || *p1 == '\0') {
        APP_ERROR("p1 is null or empty");
        return NULL;
    }

    if (p2 == NULL || *p2 == '\0') {
        APP_ERROR("p2 is null or empty");
        return NULL;
    }

    size_t p1_len = strlen(p1);
    if (is_path_separator(p1[p1_len - 1])) { p1_len--; }

    size_t p2_len = strlen(p2);
    const char *p2_start = p2;
    if (is_path_separator(*p2_start)) { p2_start++; p2_len--; }

    size_t joined_len = p1_len + 1 + p2_len;
    char *joined_path = calloc(1, joined_len + 1);
    if (!joined_path) {
        APP_ERROR("Failed to allocate buffer for join path");
        return NULL;
    }
    memcpy(joined_path, p1, p1_len);
    joined_path[p1_len] = PATH_SEPARATOR;
    memcpy(joined_path + p1_len + 1, p2_start, p2_len);
    joined_path[joined_len] = '\0';

    return joined_path;
}

char *GetParentPath(const char *path)
{
    if (!path) {
        APP_ERROR("path is NULL");
        return NULL;
    }

    size_t len = strlen(path);
    size_t i   = len;

    /* Skip any trailing separators */
    while (i > 0 && is_path_separator(path[i])) {
        i--;
    }

    /* Skip the last segment’s characters */
    while (i > 0 && !is_path_separator(path[i])) {
        i--;
    }

    /* i==0 ⇒ empty parent */

    char *out = malloc(i + 1);
    if (!out) {
        APP_ERROR("Memory allocation failed for parent path");
        return NULL;
    }
    memcpy(out, path, i);
    out[i] = '\0';
    return out;
}

/**
 * Converts a NULL-terminated UTF-16 string to a malloc-allocated UTF-8 string.
 *
 * @param utf16 Pointer to a NULL-terminated UTF-16 (wchar_t*) input string.
 * @return malloc-allocated UTF-8 string on success (caller must free()),
 *         or NULL on failure (error logged via APP_ERROR).
 */
static char *utf16_to_utf8(const wchar_t *utf16)
{
    char *utf8 = NULL;

    if (!utf16) {
        APP_ERROR("utf16 is NULL");

        goto cleanup;
    }

    int utf8_size = WideCharToMultiByte(
        CP_UTF8,
        WC_ERR_INVALID_CHARS,
        utf16, -1, NULL, 0, NULL, NULL
    );
    if (utf8_size == 0) {
        DWORD err = GetLastError();
        APP_ERROR(
            "Failed to calculate buffer size for UTF-8 conversion, Error=%lu",
            err
        );

        goto cleanup;
    }

    utf8 = malloc((size_t)utf8_size);
    if (!utf8) {
        APP_ERROR("Memory allocation failed for utf8");
        
        goto cleanup;
    }
    utf8[utf8_size - 1] = '\0';

    int written = WideCharToMultiByte(
        CP_UTF8,
        WC_ERR_INVALID_CHARS,
        utf16, -1, utf8, utf8_size, NULL, NULL
    );
    if (written == 0) {
        DWORD err = GetLastError();
        APP_ERROR("Failed to convert UTF-16 to UTF-8, Error=%lu", err);

        goto cleanup;
    } else if (written != utf8_size) {
        APP_ERROR(
            "Unexpected UTF-8 length: expected=%d, written=%d",
             utf8_size, written
        );

        goto cleanup;
    }

    return utf8;

cleanup:
    if (utf8) {
        free(utf8);
    }
    return NULL;
}

// Recursively creates a directory and all its parent directories.
bool CreateDirectoriesRecursively(const char *dir)
{
    if (!dir || !*dir) {
        APP_ERROR("dir is NULL or empty");
        return false;
    }

    DWORD dir_attr = GetFileAttributes(dir);
    if (dir_attr != INVALID_FILE_ATTRIBUTES) {
        if (dir_attr & FILE_ATTRIBUTE_DIRECTORY) {
            return true;
        } else {
            APP_ERROR("Directory name conflicts with a file(%s)", dir);
            return false;
        }
    }

    bool result = false;

    size_t path_len = strlen(dir);
    char *path = malloc(path_len + 1);
    if (!path) {
        APP_ERROR("Memory allocation failed for path");
        
        goto cleanup;
    }
    memcpy(path, dir, path_len);
    path[path_len] = '\0';

    char *end = path + path_len;
    char *p = end;
    for (; p >= path; p--) {
        if (!is_path_separator(*p)) continue;

        *p = '\0';
        DWORD path_attr = GetFileAttributes(path);
        if (path_attr != INVALID_FILE_ATTRIBUTES) {
            if (path_attr & FILE_ATTRIBUTE_DIRECTORY) {
                break;
            } else {
                APP_ERROR("Directory name conflicts with a file(%s)", path);

                goto cleanup;
            }
        } else {
            DWORD err = GetLastError();
            if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) {
                continue;
            } else {
                APP_ERROR("Cannot access the directory, Error=%lu", err);

                goto cleanup;
            }
        }
    }

    for (; p < end; p++) {
        if (*p) continue;

        *p = PATH_SEPARATOR;

        DEBUG("CreateDirectory(%s)", path);

        if (!CreateDirectory(path, NULL)) {
            DWORD err = GetLastError();
            APP_ERROR("Failed to create directory, Error=%lu", err);

            goto cleanup;
        }
    }

    result = true;

cleanup:
    if (path) {
        free(path);
    }
    return result;
}

// Deletes a directory and all its contents recursively.
bool DeleteRecursively(const char *path)
{
    if (!path || !*path) {
        APP_ERROR("path is NULL or empty");
        return false;
    }

    char *findPath = JoinPath(path, "*");
    if (!findPath) {
        APP_ERROR("Failed to build find path for deletion");
        return false;
    }

    WIN32_FIND_DATA findData;
    HANDLE handle = FindFirstFile(findPath, &findData);
    if (handle != INVALID_HANDLE_VALUE) {
        do {
            const char *name = findData.cFileName;
            if ( name[0]=='.' && (!name[1] || (name[1]=='.' && !name[2])) ) {
                continue;
            }

            char *subPath = JoinPath(path, name);
            if (!subPath) {
                APP_ERROR("Failed to build delete file path");
                break;
            }

            if (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                DeleteRecursively(subPath);
            } else if (!DeleteFile(subPath)) {
                DWORD err = GetLastError();
                APP_ERROR("Failed to delete file, Error=%lu", err);
                MoveFileEx(subPath, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
            }

            free(subPath);
        } while (FindNextFile(handle, &findData));
        FindClose(handle);
    }
    free(findPath);

    if (!RemoveDirectory(path)) {
        DWORD err = GetLastError();
        APP_ERROR("Failed to delete directory, Error=%lu", err);
        MoveFileEx(path, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
        return false;
    }
    return true;
}

char *GenerateUniqueName(const char *prefix)
{
    if (!prefix) {
        APP_ERROR("prefix is NULL");
        return NULL;
    }

    size_t prefix_len = strlen(prefix);
    char *name = malloc(prefix_len + UID_LENGTH + 1);
    if (!name) {
        APP_ERROR("Memory allocation failed for unique name");
        return NULL;
    }
    memcpy(name, prefix, prefix_len);

    LARGE_INTEGER time;
    // This function always succeeds on Windows XP and later
    QueryPerformanceCounter(&time);
    unsigned long long timestamp = time.QuadPart;
    char hex[] = "0123456789ABCDEF";
    char *t = name + prefix_len;
    for (int i = 0; i < UID_LENGTH; i++) {
        t[i] = hex[(timestamp >> (4 * (UID_LENGTH - 1 - i))) & 0xF];
    }
    t[UID_LENGTH] = '\0';

    return name;
}

// Generates a unique directory within a specified base path using a prefix.
char *CreateUniqueDirectory(const char *base_path, const char *prefix)
{
    if (!base_path) {
        APP_ERROR("base_path is NULL");
        return NULL;
    }

    size_t retry_limit = MAX_RETRY_CREATE_UNIQUE_DIR;
    for (size_t retry = 0; retry < retry_limit; retry++) {
        char *temp_name = GenerateUniqueName(prefix);
        if (!temp_name) {
            APP_ERROR("Failed to generate a unique name");
            return NULL;
        }

        char *full_path = JoinPath(base_path, temp_name);
        free(temp_name);
        if (!full_path) {
            APP_ERROR("Failed to construct a unique directory path");
            return NULL;
        }

        if (CreateDirectory(full_path, NULL)) {
            return full_path;
        }
        DWORD err = GetLastError();
        free(full_path);
        if (err != ERROR_ALREADY_EXISTS) {
            APP_ERROR("Failed to create a unique directory, Error=%lu", err);
            return NULL;
        }

        /* To avoid sequential generation and prevent name duplication. */
        Sleep(10); 
    }

    APP_ERROR(
        "Failed to create a unique directory after %u retries",
        retry_limit
    );
    return NULL;
}

// MAX_EXTENDED_PATH_LENGTH: Maximum path length in Windows (32,767 chars).
#define MAX_EXTENDED_PATH_LENGTH 32767U

// Retrieves the full path to the executable file of the current process
char *GetImagePath(void)
{
    char *image_path_utf8 = NULL;

    wchar_t *image_path_w = calloc(MAX_EXTENDED_PATH_LENGTH,
                                   sizeof(*image_path_w));
    if (!image_path_w) {
        APP_ERROR("Memory allocation failed for image path");

        goto cleanup;
    }

    DWORD copied = GetModuleFileNameW(
        NULL,                           // current exe path
        image_path_w,                   // wide-char buffer for path
        MAX_EXTENDED_PATH_LENGTH        // buffer size in WCHARs
    );
    if (copied == 0) {
        DWORD err = GetLastError();
        APP_ERROR("GetModuleFileNameW failed, Error=%lu", err);

        goto cleanup;
    }
    if (GetLastError() == ERROR_INSUFFICIENT_BUFFER) {
        APP_ERROR("Image path truncated; buffer too small");
        
        goto cleanup;
    }

    image_path_utf8 = utf16_to_utf8(image_path_w);
    if (!image_path_utf8) {
        APP_ERROR("Failed to convert image path to UTF-8");

        goto cleanup;
    }

cleanup:
    if (image_path_w) {
        free(image_path_w);
    }
    return image_path_utf8;
}

// Retrieves the directory path of the executable file of the current process.
char *GetImageDirectoryPath(void) {
    char *image_path = GetImagePath();
    if (image_path == NULL) {
        APP_ERROR("Failed to get executable name (%lu)", GetLastError());
        return NULL;
    }

    char *image_dir = GetParentPath(image_path);
    if (!image_dir) {
        APP_ERROR("Failed to get parent path");
        free(image_path);
        return NULL;
    }
    if (image_dir[0] == '\0') {
        APP_ERROR("Executable path does not contain a directory");
        free(image_dir);
        free(image_path);
        return NULL;
    }

    return image_dir;
}

// Retrieves the path to the temporary directory for the current user.
char *GetTempDirectoryPath(void)
{
    char *temp_dir = calloc(1, MAX_PATH);
    if (!temp_dir) {
        APP_ERROR("Failed to memory allocate for get temp directory");
        return NULL;
    }

    if (!GetTempPath(MAX_PATH, temp_dir)) {
        APP_ERROR("Failed to get temp path (%lu)", GetLastError());
        free(temp_dir);
        return NULL;
    }

    return temp_dir;
}

bool ChangeWorkingDirectory(const char* path)
{
    if (!path || !*path) {
        APP_ERROR("path is NULL or empty");
        return false;
    }

    if (!SetCurrentDirectory(path)) {
        DWORD err = GetLastError();
        APP_ERROR(
            "Failed to change working dir to \"%s\", Error=%lu",
            path, err
        );
        return false;
    }
    return true;
}

bool ExportFile(const char *path, const void *buffer, size_t buffer_size)
{
    bool   result  = false;
    char  *parent  = NULL;
    HANDLE hFile   = INVALID_HANDLE_VALUE;
    DWORD  written = 0;

    if (buffer_size > MAXDWORD) {
        APP_ERROR(
            "ExportFile: Write length %zu exceeds maximum DWORD",
            buffer_size
        );

        goto cleanup;
    }

    parent = GetParentPath(path);
    if (!parent) {
        APP_ERROR("Failed to get parent path");

        goto cleanup;
    }

    if (!CreateDirectoriesRecursively(parent)) {
        APP_ERROR("ExportFile: Failed to create parent directory for %s", path);
        
        goto cleanup;
    }

    hFile = CreateFile(
        path,                       // file path
        GENERIC_WRITE,              // write-only access (like O_WRONLY)
        0,                          // no sharing (exclusive)
        NULL,                       // default security
        CREATE_ALWAYS,              // create or overwrite (O_CREAT|O_TRUNC)
        FILE_ATTRIBUTE_NORMAL,      // normal file (no special flags)
        NULL                        // no template file
    );
    if (hFile == INVALID_HANDLE_VALUE) {
        DWORD err = GetLastError();
        APP_ERROR("ExportFile: CreateFile failed, Error=%u", err);

        goto cleanup;
    }

    if (!WriteFile(hFile, buffer, (DWORD)buffer_size, &written, NULL)) {
        DWORD err = GetLastError();
        APP_ERROR("ExportFile: WriteFile failed, Error=%u", err);

        goto cleanup;
    }

    if (written != (DWORD)buffer_size) {
        APP_ERROR(
            "ExportFile: Write size mismatch, expected %zu, wrote %u",
            buffer_size, written
        );
        
        goto cleanup;
    }

    result = true;

cleanup:
    if (parent) {
        free(parent);
    }
    if (hFile != INVALID_HANDLE_VALUE) {
        CloseHandle(hFile);
    }
    return result;
}

struct MemoryMap {
    void   *base;       // Base address of the mapping
    size_t  size;       // Length of the mapping
};

MemoryMap *CreateMemoryMap(const char *path)
{
    if (!path) {
        APP_ERROR("CreateMemoryMap: path is NULL");
        return NULL;
    }

    MemoryMap *map = malloc(sizeof(*map));
    if (!map) {
        APP_ERROR("CreateMemoryMap: Memory allocation failed for map");
        return NULL;
    }

    HANDLE hFile = INVALID_HANDLE_VALUE;
    HANDLE hMapping = NULL;  // section object handle for mapping
    LPVOID base = NULL;

    /*
     * Open the target file for memory mapping:
     *   - Read-only access; write and delete operations are denied.
     *   - Allows other processes to open the file for read-only access.
     *   - Fails if the file does not exist.
     *   - Sets the file’s attribute to read-only.
     *   - Hints OS to optimize for sequential access after initial random read.
     */

    hFile = CreateFile(
        path,                           // path to existing file
        GENERIC_READ,                   // read-only access
        FILE_SHARE_READ,                // share read, deny write/delete
        NULL,                           // default security
        OPEN_EXISTING,                  // open only if file exists
        FILE_ATTRIBUTE_READONLY         // read-only attribute
      | FILE_FLAG_SEQUENTIAL_SCAN,      // then optimize for sequential access
        NULL                            // no template file
    );
    if (hFile == INVALID_HANDLE_VALUE) {
        DWORD err = GetLastError();
        APP_ERROR(
            "CreateMemoryMap: CreateFile(\"%s\") failed, Error=%lu",
            path, err
        );

        goto cleanup;
    }

    LARGE_INTEGER fileSize;
    if (!GetFileSizeEx(hFile, &fileSize)) {
        DWORD err = GetLastError();
        APP_ERROR(
            "CreateMemoryMap: GetFileSizeEx failed, Error=%lu",
            err
        );

        goto cleanup;
    }
    
    /*
     * Verify that the file size obtained at runtime does not exceed the
     * maximum value representable by size_t on this platform. This check
     * prevents an overflow when casting the 64-bit file size to size_t,
     * which may be 32 bits on some environments.
     */

    if (fileSize.QuadPart < 0
        || (ULONGLONG)fileSize.QuadPart > (ULONGLONG)SIZE_MAX) {
        APP_ERROR(
            "CreateMemoryMap: file too large (%lld bytes)",
            fileSize.QuadPart
        );

        goto cleanup;
    }

    map->size = (size_t)fileSize.QuadPart;

    hMapping = CreateFileMapping(
        hFile,              // read-only file handle
        NULL,               // default security attributes
        PAGE_READONLY,      // read-only mapping protection
        0,                  // max size high 32-bit (0 = full file)
        0,                  // max size low 32-bit  (0 = full file)
        NULL                // unnamed mapping (private)
    );
    if (!hMapping) {
        DWORD err = GetLastError();
        APP_ERROR(
            "CreateMemoryMap: CreateFileMapping(hFile) failed, Error=%lu",
            err
        );

        goto cleanup;
    }

    CloseHandle(hFile);
    hFile = INVALID_HANDLE_VALUE;

    base = MapViewOfFile(
        hMapping,           // handle returned by CreateFileMapping
        FILE_MAP_READ,      // read-only access to mapped view
        0,                  // file offset high 32 bits (start at 0)
        0,                  // file offset low 32 bits  (start at 0)
        0                   // number of bytes to map (0 = entire file)
    );
    if (!base) {
        DWORD err = GetLastError();
        APP_ERROR(
            "CreateMemoryMap: MapViewOfFile(hMapping) failed, Error=%lu",
            err
        );

        goto cleanup;
    }

    CloseHandle(hMapping);
    hMapping = NULL;

    map->base = base;
    return map;

cleanup:
    if (base) {
        UnmapViewOfFile(base);
    }
    if (hMapping) {
        CloseHandle(hMapping);
    }
    if (hFile != INVALID_HANDLE_VALUE) {
        CloseHandle(hFile);
    }
    free(map);
    return NULL;
}

void DestroyMemoryMap(MemoryMap *map)
{
    if (!map) {
        APP_ERROR("DestroyMemoryMap: map is NULL");
        return;
    }

    if (map->base) {
        if (!UnmapViewOfFile(map->base)) {
            DWORD err = GetLastError();
            APP_ERROR(
                "DestroyMemoryMap: UnmapViewOfFile failed, Error=%lu",
                err
            );
        }
        map->base = NULL;
    }

    free(map);
}

void *GetMemoryMapBase(const MemoryMap *map)
{
    if (!map) {
        APP_ERROR("GetMemoryMapBase: map is NULL");
        return NULL;
    }
    return map->base;
}

size_t GetMemoryMapSize(const MemoryMap *map)
{
    if (!map) {
        APP_ERROR("GetMemoryMapSize: map is NULL");
        return 0;
    }
    return map->size;
}

/**
 * @brief Handle console control events in the parent process.
 *
 * This handler ignores all console control events (Ctrl+C, Ctrl+Break, etc.)
 * in the parent process so it can complete cleanup without interruption.
 * Child processes (e.g., Ruby) receive these events and exit quickly,
 * allowing the parent to perform final cleanup tasks.
 *
 * @param dwCtrlType The type of console control event received.
 * @return TRUE to indicate the event was handled and should be ignored.
 */
static BOOL WINAPI ConsoleHandleRoutine(DWORD dwCtrlType)
{
    return TRUE;
}

bool InitializeSignalHandling(void)
{
    if (!SetConsoleCtrlHandler(ConsoleHandleRoutine, TRUE)) {
        DWORD err = GetLastError();
        APP_ERROR("Failed to set console control handler, Error=%lu", err);
        return false;
    }
    return true;
}

bool SetEnvVar(const char *name, const char *value)
{
    if (!name) {
        APP_ERROR("name is NULL");
        return false;
    }

    if (!SetEnvironmentVariable(name, value)) {
        DWORD err = GetLastError();
        APP_ERROR("Failed to set environment variable, Error=%lu", err);
        return false;
    }
    return true;
}
