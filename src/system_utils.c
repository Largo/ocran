#include <windows.h>
#include <ntstatus.h>
#include <ntdef.h>
#include <bcrypt.h>
#include <stdbool.h>
#include "error.h"
#include "system_utils.h"

char *ToLongPath(const char *path)
{
    if (!path) {
        return NULL;
    }

    DWORD required = GetLongPathName(path, NULL, 0);
    if (required == 0) {
        return _strdup(path); /* e.g. path does not exist - keep as is */
    }

    char *buf = malloc(required);
    if (!buf) {
        APP_ERROR("Memory allocation failed for long path");
        return NULL;
    }

    DWORD written = GetLongPathName(path, buf, required);
    if (written == 0 || written >= required) {
        free(buf);
        return _strdup(path);
    }

    return buf;
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
        return NULL;
    }

    char *utf8 = calloc((size_t)utf8_size, sizeof(*utf8));
    if (!utf8) {
        APP_ERROR("Memory allocation failed for UTF-8 conversion");
        return NULL;
    }

    int written = WideCharToMultiByte(
        CP_UTF8,
        WC_ERR_INVALID_CHARS,
        utf16, -1, utf8, utf8_size, NULL, NULL
    );
    if (written == 0) {
        DWORD err = GetLastError();
        APP_ERROR("Failed to convert UTF-16 to UTF-8, Error=%lu", err);
        free(utf8);
        return NULL;
    }
    return utf8;
}

/**
 * Converts a NULL-terminated UTF-8 string to a malloc-allocated UTF-16 string.
 *
 * @param utf8 Pointer to a NULL-terminated UTF-8 (char*) input string.
 * @return malloc-allocated UTF-16 string on success (caller must free()),
 *         or NULL on failure (error logged via APP_ERROR).
 */
static wchar_t *utf8_to_utf16(const char *utf8)
{
    if (!utf8) {
        APP_ERROR("utf8 is NULL");
        return NULL;
    }

    int utf16_size = MultiByteToWideChar(
        CP_UTF8,
        MB_ERR_INVALID_CHARS,
        utf8, -1, NULL, 0
    );
    if (utf16_size == 0) {
        DWORD err = GetLastError();
        APP_ERROR(
            "Failed to calculate buffer size for UTF-16 conversion, Error=%lu",
            err
        );
        return NULL;
    }

    wchar_t *utf16 = calloc((size_t)utf16_size, sizeof(*utf16));
    if (!utf16) {
        APP_ERROR("Memory allocation failed for UTF-16 conversion");
        return NULL;
    }

    int written = MultiByteToWideChar(
        CP_UTF8,
        MB_ERR_INVALID_CHARS,
        utf8, -1, utf16, utf16_size
    );
    if (written == 0) {
        DWORD err = GetLastError();
        APP_ERROR("Failed to convert UTF-8 to UTF-16, Error=%lu", err);
        free(utf16);
        return NULL;
    }
    return utf16;
}

// Recursively creates a directory and all its parent directories.
bool CreateDirectoriesRecursively(const char *dir)
{
    if (!dir || !*dir) {
        APP_ERROR("dir is NULL or empty");
        return false;
    }

    bool result = false;
    wchar_t *wpath = NULL;

    size_t path_len = strlen(dir);
    char *path = malloc(path_len + 1);
    if (!path) {
        APP_ERROR("Memory allocation failed for path");

        goto cleanup;
    }
    memcpy(path, dir, path_len);
    path[path_len] = '\0';

    char *p = path + path_len;
    do {
        // Convert to UTF-16 for API call
        wpath = utf8_to_utf16(path);
        if (!wpath) {
            APP_ERROR("Failed to convert path to UTF-16");
            goto cleanup;
        }

        DWORD path_attr = GetFileAttributesW(wpath);
        if (path_attr != INVALID_FILE_ATTRIBUTES) {
            if (path_attr & FILE_ATTRIBUTE_DIRECTORY) {
                free(wpath);
                wpath = NULL;
                break;
            } else {
                APP_ERROR("Directory name conflicts with a file(%s)", path);
                goto cleanup;
            }
        } else {
            DWORD err = GetLastError();
            if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) {
                // continue;
            } else {
                APP_ERROR("Cannot access the directory, Error=%lu", err);
                goto cleanup;
            }
        }

        free(wpath);
        wpath = NULL;

        while (p > path && !is_path_separator(*p)) {
            p--;
        }
        *p = '\0';
    } while (p >= path);

    char *end = path + path_len;
    for (; p < end; p++) {
        if (*p) continue;

        *p = PATH_SEPARATOR;

        // Convert to UTF-16 for API call
        wpath = utf8_to_utf16(path);
        if (!wpath) {
            APP_ERROR("Failed to convert path to UTF-16");
            goto cleanup;
        }

        if (!CreateDirectoryW(wpath, NULL)) {
            DWORD err = GetLastError();
            APP_ERROR("Failed to create directory '%s', Error=%lu", path, err);
            goto cleanup;
        }

        free(wpath);
        wpath = NULL;
    }

    result = true;

cleanup:
    if (wpath) {
        free(wpath);
    }
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

    wchar_t *wfindPath = utf8_to_utf16(findPath);
    free(findPath);
    if (!wfindPath) {
        APP_ERROR("Failed to convert find path to UTF-16");
        return false;
    }

    WIN32_FIND_DATAW findData;
    HANDLE handle = FindFirstFileW(wfindPath, &findData);
    free(wfindPath);

    if (handle != INVALID_HANDLE_VALUE) {
        do {
            const wchar_t *wname = findData.cFileName;
            if ( wname[0]==L'.' && (!wname[1] || (wname[1]==L'.' && !wname[2])) ) {
                continue;
            }

            // Convert filename from UTF-16 to UTF-8
            char *name = utf16_to_utf8(wname);
            if (!name) {
                APP_ERROR("Failed to convert filename to UTF-8");
                continue;
            }

            char *subPath = JoinPath(path, name);
            free(name);
            if (!subPath) {
                APP_ERROR("Failed to build delete file path");
                break;
            }

            wchar_t *wsubPath = utf8_to_utf16(subPath);
            if (!wsubPath) {
                APP_ERROR("Failed to convert subpath to UTF-16");
                free(subPath);
                continue;
            }

            DWORD attrs = findData.dwFileAttributes;
            if ((attrs & FILE_ATTRIBUTE_DIRECTORY)
                && (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) {
                // A junction or directory symlink: remove the link itself.
                // Recursing would delete the contents of its target, which
                // lies outside the directory being deleted.
                if (!RemoveDirectoryW(wsubPath)) {
                    DWORD err = GetLastError();
                    APP_ERROR("Failed to delete directory link, Error=%lu", err);
                }
            } else if (attrs & FILE_ATTRIBUTE_DIRECTORY) {
                DeleteRecursively(subPath);
            } else if (!DeleteFileW(wsubPath)) {
                DWORD err = GetLastError();
                APP_ERROR("Failed to delete file, Error=%lu", err);
                MoveFileExW(wsubPath, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
            }

            free(wsubPath);
            free(subPath);
        } while (FindNextFileW(handle, &findData));
        FindClose(handle);
    }

    wchar_t *wpath = utf8_to_utf16(path);
    if (!wpath) {
        APP_ERROR("Failed to convert path to UTF-16");
        return false;
    }

    if (!RemoveDirectoryW(wpath)) {
        DWORD err = GetLastError();
        APP_ERROR("Failed to delete directory, Error=%lu", err);
        MoveFileExW(wpath, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
        free(wpath);
        return false;
    }
    free(wpath);
    return true;
}

static bool generate_unique_name(char *buffer, size_t buffer_size)
{
    char base32[] = "0123456789ABCDEF"
                    "GHIJKLMNOPQRSTUV"
    ;

    NTSTATUS b = BCryptGenRandom(
        0,
        (PUCHAR)buffer,
        buffer_size,
        BCRYPT_USE_SYSTEM_PREFERRED_RNG
    );
    if (!NT_SUCCESS(b)) {
        return false;
    }

    for (size_t i = 0; i < buffer_size; i++) {
        buffer[i] = base32[buffer[i] & 0x1F];
    }
    return true;
}

// Defines the maximum number of attempts to create a unique directory.
#define MAX_RETRY_CREATE_UNIQUE_DIR 20U

// Generates a unique directory within a specified base path using a prefix.
char *CreateUniqueDirectory(char *tmpl)
{
    if (!tmpl || !*tmpl) {
        APP_ERROR("template is NULL or empty");
        return NULL;
    }

    size_t tmpl_len = strlen(tmpl);
    char  *tmpl_end = tmpl + tmpl_len;
    char  *x_str = tmpl_end;
    size_t x_len = 0;
    while (x_str > tmpl && *--x_str == 'X') {
        x_len++;
    }
    if (x_len < 6) {
        APP_ERROR("Template must end with at least six 'X's");
        return NULL;
    }
    char *x_head = tmpl_end - x_len;

    for (size_t retry = 0; retry < MAX_RETRY_CREATE_UNIQUE_DIR; retry++) {
        if (!generate_unique_name(x_head, x_len)) {
            APP_ERROR("Failed to construct a unique directory path");
            return NULL;
        }

        wchar_t *wtmpl = utf8_to_utf16(tmpl);
        if (!wtmpl) {
            APP_ERROR("Failed to convert template path to UTF-16");
            return NULL;
        }

        BOOL created = CreateDirectoryW(wtmpl, NULL);
        DWORD err = GetLastError();
        free(wtmpl);

        if (created) {
            return tmpl;
        }
        if (err != ERROR_ALREADY_EXISTS) {
            APP_ERROR("Failed to create a unique directory, Error=%lu", err);
            return NULL;
        }
    }

    APP_ERROR(
        "Failed to create a unique directory after %u retries",
        MAX_RETRY_CREATE_UNIQUE_DIR
    );
    return NULL;
}

// Maximum path length in Windows (32,767 chars).
#define MAX_LONG_PATH 32767U

// Retrieves the full path to the executable file of the current process
char *GetImagePath(void)
{
    char *image_path = NULL;

    wchar_t *wimage_path = calloc(MAX_LONG_PATH, sizeof(*wimage_path));
    if (!wimage_path) {
        APP_ERROR("Memory allocation failed for image path");

        goto cleanup;
    }

    DWORD copied = GetModuleFileNameW(NULL, wimage_path, MAX_LONG_PATH);
    if (copied == 0) {
        DWORD err = GetLastError();
        APP_ERROR("GetModuleFileNameW failed, Error=%lu", err);

        goto cleanup;
    }
    if (copied == MAX_LONG_PATH
        && GetLastError() == ERROR_INSUFFICIENT_BUFFER) {
        APP_ERROR("Image path truncated; buffer too small");
        
        goto cleanup;
    }

    image_path = utf16_to_utf8(wimage_path);
    if (!image_path) {
        APP_ERROR("Failed to convert image path to UTF-8");

        goto cleanup;
    }

cleanup:
    if (wimage_path) {
        free(wimage_path);
    }
    return image_path;
}

// Retrieves the path to the temporary directory for the current user.
char *GetTempDirectoryPath(void)
{
    wchar_t *wtemp_dir = calloc(MAX_PATH, sizeof(*wtemp_dir));
    if (!wtemp_dir) {
        APP_ERROR("Memory allocation failed for temp directory");
        return NULL;
    }

    if (!GetTempPathW(MAX_PATH, wtemp_dir)) {
        DWORD err = GetLastError();
        APP_ERROR("Failed to get temp path, Error=%lu", err);
        free(wtemp_dir);
        return NULL;
    }

    char *temp_dir = utf16_to_utf8(wtemp_dir);
    free(wtemp_dir);
    if (!temp_dir) {
        APP_ERROR("Failed to convert temp path to UTF-8");
        return NULL;
    }
    return temp_dir;
}

bool ExportFile(const char *path, const void *buffer, size_t buffer_size)
{
    bool     result  = false;
    char    *parent  = NULL;
    wchar_t *wpath   = NULL;
    HANDLE   hFile   = INVALID_HANDLE_VALUE;
    DWORD    written = 0;

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

    // Convert UTF-8 path to UTF-16 for proper multibyte support
    wpath = utf8_to_utf16(path);
    if (!wpath) {
        APP_ERROR("ExportFile: Failed to convert path to UTF-16");
        goto cleanup;
    }

    hFile = CreateFileW(
        wpath,                      // file path (UTF-16)
        GENERIC_WRITE,              // write-only access (like O_WRONLY)
        0,                          // no sharing (exclusive)
        NULL,                       // default security
        CREATE_ALWAYS,              // create or overwrite (O_CREAT|O_TRUNC)
        FILE_ATTRIBUTE_NORMAL,      // normal file (no special flags)
        NULL                        // no template file
    );
    if (hFile == INVALID_HANDLE_VALUE) {
        DWORD err = GetLastError();
        APP_ERROR("ExportFile: CreateFileW failed, Error=%u", err);

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
    if (wpath) {
        free(wpath);
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
    wchar_t *wpath = NULL;

    /*
     * Open the target file for memory mapping:
     *   - Read-only access; write and delete operations are denied.
     *   - Allows other processes to open the file for read-only access.
     *   - Fails if the file does not exist.
     *   - Sets the file's attribute to read-only.
     *   - Hints OS to optimize for sequential access after initial random read.
     */

    // Convert UTF-8 path to UTF-16 for proper multibyte support
    wpath = utf8_to_utf16(path);
    if (!wpath) {
        APP_ERROR("CreateMemoryMap: Failed to convert path to UTF-16");
        goto cleanup;
    }

    hFile = CreateFileW(
        wpath,                          // path to existing file (UTF-16)
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
            "CreateMemoryMap: CreateFileW(\"%s\") failed, Error=%lu",
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
    if (wpath) {
        free(wpath);
    }
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
    if (wpath) {
        free(wpath);
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

/* Guards ChildProcess and TerminationRequested, which the console control
   handler thread reads while the main thread launches and reaps the child. */
static CRITICAL_SECTION ChildLock;

/* Process handle of the running child; NULL while there is none. */
static HANDLE ChildProcess = NULL;

/* Set by the console control handler when Windows is about to terminate
   the stub; the main thread then no longer starts the child. */
static bool TerminationRequested = false;

/* State of the cleanup routine, see RunCleanupRoutine(). */
#define CLEANUP_PENDING 0
#define CLEANUP_RUNNING 1
#define CLEANUP_DONE    2
static void (*CleanupRoutine)(void) = NULL;
static volatile LONG CleanupState = CLEANUP_PENDING;

void SetCleanupRoutine(void (*routine)(void))
{
    CleanupRoutine = routine;
}

void RunCleanupRoutine(void)
{
    if (InterlockedCompareExchange(&CleanupState, CLEANUP_RUNNING,
                                   CLEANUP_PENDING) == CLEANUP_PENDING) {
        if (CleanupRoutine) {
            CleanupRoutine();
        }
        InterlockedExchange(&CleanupState, CLEANUP_DONE);
        return;
    }

    /* The other thread is running it: wait until it is done, so that
       neither thread ends the process in the middle of the cleanup. */
    while (CleanupState != CLEANUP_DONE) {
        Sleep(10);
    }
}

/* Windows terminates the stub about 5 seconds after a close or shutdown
   event. These split that time between the child and the cleanup. */
#define CLOSE_CHILD_WAIT_MS     2500
#define CLOSE_TERMINATE_WAIT_MS 500
#define CLOSE_EXTRACT_WAIT_MS   2500

/**
 * @brief Handle console control events in the parent process.
 *
 * Ctrl+C and Ctrl+Break are ignored in the parent: the child shares the
 * console, receives the same event and decides whether to exit, and the
 * parent cleans up after it as usual.
 *
 * Closing the console window and system shutdown are different: Windows
 * terminates the process as soon as this handler returns, whatever it
 * returns, so the cleanup has to happen here. The handler waits for the
 * child (which got the same event) for a bounded time, ends it if it is
 * still running (its open files could not be deleted otherwise), and runs
 * the cleanup routine before returning. Should the stub still be extracting,
 * the main thread does not start the child any more and the handler gives
 * it a moment to reach its own cleanup first.
 *
 * CTRL_LOGOFF_EVENT is ignored like Ctrl+C: it reaches only services, and
 * does so whenever any user logs off, which a service has to survive.
 *
 * Runs on a thread of its own that Windows creates for the event.
 *
 * @param dwCtrlType The type of console control event received.
 * @return TRUE to indicate the event was handled.
 */
static BOOL WINAPI ConsoleHandleRoutine(DWORD dwCtrlType)
{
    if (dwCtrlType != CTRL_CLOSE_EVENT && dwCtrlType != CTRL_SHUTDOWN_EVENT) {
        return TRUE;
    }

    DEBUG("Console control event %lu: cleaning up before Windows ends the stub",
          (unsigned long)dwCtrlType);

    HANDLE child = NULL;
    EnterCriticalSection(&ChildLock);
    TerminationRequested = true;
    if (ChildProcess
        && !DuplicateHandle(GetCurrentProcess(), ChildProcess,
                            GetCurrentProcess(), &child,
                            0, FALSE, DUPLICATE_SAME_ACCESS)) {
        child = NULL;
    }
    LeaveCriticalSection(&ChildLock);

    if (child) {
        if (WaitForSingleObject(child, CLOSE_CHILD_WAIT_MS) == WAIT_TIMEOUT) {
            DEBUG("The application did not exit in time; terminating it");
            TerminateProcess(child, (UINT)STATUS_CONTROL_C_EXIT);
            WaitForSingleObject(child, CLOSE_TERMINATE_WAIT_MS);
        }
        CloseHandle(child);
    } else {
        DWORD start = GetTickCount();
        while (CleanupState == CLEANUP_PENDING
               && GetTickCount() - start < CLOSE_EXTRACT_WAIT_MS) {
            Sleep(10);
        }
    }

    RunCleanupRoutine();
    return TRUE;
}

bool InitializeSignalHandling(void)
{
    InitializeCriticalSection(&ChildLock);

    if (!SetConsoleCtrlHandler(ConsoleHandleRoutine, TRUE)) {
        DWORD err = GetLastError();
        APP_ERROR("Failed to set console control handler, Error=%lu", err);
        return false;
    }
    return true;
}

/* Windows has no signal deaths to reproduce: the exit code says it all. */
void ReraiseChildSignal(void)
{
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

static size_t quoted_arg(char *quoted, const char* arg)
{
    size_t count = 0;

    count++;
    if (quoted) {
        *quoted++ = '"';
    }

    for (const char *p = arg; *p; p++) {
        switch (*p) {
            case '\\': {
                size_t trail = 1;
                while (*++p == '\\') {
                    trail++;
                }
                if (*p == '"' || *p == '\0') {
                    trail *= 2;
                }
                count += trail;
                if (quoted) {
                    while (trail--) *quoted++ = '\\';
                }
                p--;
                break;
            }
            case '"':
                count += 2;
                if (quoted) {
                    *quoted++ = '\\';
                    *quoted++ = '"';
                }
                break;
            default:
                count++;
                if (quoted) {
                    *quoted++ = *p;
                }
                break;
        }
    }

    count++;
    if (quoted) {
        *quoted++ = '"';
        *quoted   = '\0';
    }
    return count;
}

static size_t quoted_args(char *args, char *argv[])
{
    size_t args_len = 0;

    for (char **p = argv; *p; p++) {
        if (args_len > 0) {
            if (args) {
                args[args_len] = ' ';    
            }
            args_len++;
        }
        if (args) {
            args_len += quoted_arg(&args[args_len], *p);
        } else {
            args_len += quoted_arg(NULL, *p);
        }
    }

    if (args) {
        args[args_len] = '\0';
    }
    return args_len;
}

/*
 * Creates a job that kills its processes when its last handle is closed,
 * i.e. when the stub exits or is killed, so that ending the stub (Task
 * Manager, taskkill /F, a service manager) does not orphan the application.
 * Processes in the job may create children outside of it, so only the
 * direct child is tied to the stub: whatever the application starts is
 * not affected. The handle is not inheritable, and must stay open for as
 * long as the child runs. Returns NULL on failure.
 */
static HANDLE create_kill_on_close_job(void)
{
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (!job) {
        DEBUG("CreateJobObjectW failed (%lu)", GetLastError());
        return NULL;
    }

    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    ZeroMemory(&info, sizeof(info));
    info.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                 &info, sizeof(info))) {
        DEBUG("SetInformationJobObject failed (%lu)", GetLastError());
        CloseHandle(job);
        return NULL;
    }
    return job;
}

bool CreateAndWaitForProcess(const char *app_name, char *argv[], int *exit_code)
{
    PROCESS_INFORMATION pi = { 0 };
    STARTUPINFOW        si = { .cb = sizeof(si) };
    HANDLE job = NULL;
    bool result = false;
    char    *cmd_line  = NULL;
    wchar_t *wapp_name = NULL;
    wchar_t *wcmd_line = NULL;

    cmd_line = calloc(quoted_args(NULL, argv) + 1, sizeof(*cmd_line));
    if (!cmd_line) {
        APP_ERROR("Failed to build command line for CreateProcessW()");
        goto cleanup;
    }
    quoted_args(cmd_line, argv);

    DEBUG("ApplicationName=%s", app_name);
    DEBUG("CommandLine=%s", cmd_line);

    wapp_name = utf8_to_utf16(app_name);
    if (!wapp_name) {
        APP_ERROR("Failed to convert application name to UTF-16");
        goto cleanup;
    }

    wcmd_line = utf8_to_utf16(cmd_line);
    if (!wcmd_line) {
        APP_ERROR("Failed to convert command line to UTF-16");
        goto cleanup;
    }

    /* Launch under ChildLock, so that the console control handler either
       sees the child or keeps it from being started at all. */
    EnterCriticalSection(&ChildLock);
    if (TerminationRequested) {
        LeaveCriticalSection(&ChildLock);
        APP_ERROR("Windows is terminating the stub; not starting the application");
        goto cleanup;
    }
    /* Suspended, so that the child is in the job before it runs any code. */
    if (!CreateProcessW(wapp_name, wcmd_line, NULL, NULL, TRUE, CREATE_SUSPENDED,
                        NULL, NULL, &si, &pi)) {
        DWORD err = GetLastError();
        LeaveCriticalSection(&ChildLock);
        APP_ERROR("Failed to create process (%lu)", err);
        goto cleanup;
    }
    ChildProcess = pi.hProcess;
    LeaveCriticalSection(&ChildLock);

    /* Tying the child to the stub is best effort: a job the stub itself
       runs in may forbid it, which must not keep the application from
       starting. */
    job = create_kill_on_close_job();
    if (job && !AssignProcessToJobObject(job, pi.hProcess)) {
        DEBUG("Could not assign the application to a job (%lu); it will "
              "outlive the stub if the stub is killed", GetLastError());
        CloseHandle(job);
        job = NULL;
    }

    if (ResumeThread(pi.hThread) == (DWORD)-1) {
        APP_ERROR("Failed to start the application (%lu)", GetLastError());
        TerminateProcess(pi.hProcess, 1);
        goto cleanup;
    }

    if (WaitForSingleObject(pi.hProcess, INFINITE) != WAIT_OBJECT_0) {
        APP_ERROR("Failed to wait script process (%lu)", GetLastError());
        goto cleanup;
    }

    if (!GetExitCodeProcess(pi.hProcess, (LPDWORD)exit_code)) {
        APP_ERROR("Failed to get exit status (%lu)", GetLastError());
        goto cleanup;
    }

    result = true;

cleanup:
    if (cmd_line) {
        free(cmd_line);
    }
    if (wapp_name) {
        free(wapp_name);
    }
    if (wcmd_line) {
        free(wcmd_line);
    }
    if (pi.hProcess && pi.hProcess != INVALID_HANDLE_VALUE) {
        /* The console control handler duplicates the handle under the
           lock; unpublish it before closing it. */
        EnterCriticalSection(&ChildLock);
        ChildProcess = NULL;
        LeaveCriticalSection(&ChildLock);
        CloseHandle(pi.hProcess);
    }
    if (pi.hThread && pi.hThread != INVALID_HANDLE_VALUE) {
        CloseHandle(pi.hThread);
    }
    if (job) {
        /* Kills the child if it still runs, which happens only when
           waiting for it failed. */
        CloseHandle(job);
    }
    return result;
}
