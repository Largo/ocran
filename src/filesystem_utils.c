#include <windows.h>
#include "error.h"
#include "filesystem_utils.h"

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
    if (p1[p1_len - 1] == PATH_SEPARATOR) { p1_len--; }

    size_t p2_len = strlen(p2);
    const char *p2_start = p2;
    if (*p2_start == PATH_SEPARATOR) { p2_start++; p2_len--; }

    size_t joined_len = p1_len + 1 + p2_len;
    char *joined_path = (char *)LocalAlloc(LPTR, joined_len + 1);
    if (joined_path == NULL) {
        APP_ERROR("Failed to allocate buffer for join path (%lu)", GetLastError());
        return NULL;
    }
    memcpy(joined_path, p1, p1_len);
    joined_path[p1_len] = PATH_SEPARATOR;
    memcpy(joined_path + p1_len + 1, p2_start, p2_len);
    joined_path[joined_len] = '\0';

    return joined_path;
}

// Recursively creates a directory and all its parent directories.
bool CreateDirectoriesRecursively(const char *dir)
{
    if (dir == NULL || *dir == '\0') {
        APP_ERROR("dir is null or empty");
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

    size_t dir_len = strlen(dir);
    char *path = (char *)LocalAlloc(LPTR, dir_len + 1);
    if (path == NULL) {
        APP_ERROR("LocalAlloc failed (%lu)", GetLastError());
        return false;
    }
    strcpy(path, dir);

    char *end = path + dir_len;
    char *p = end;
    for (; p >= path; p--) {
        if (*p == PATH_SEPARATOR) {
            *p = '\0';
            DWORD path_attr = GetFileAttributes(path);
            if (path_attr != INVALID_FILE_ATTRIBUTES) {
                if (path_attr & FILE_ATTRIBUTE_DIRECTORY) {
                    break;
                } else {
                    APP_ERROR("Directory name conflicts with a file(%s)", path);
                    LocalFree(path);
                    return false;
                }
            } else {
                DWORD error = GetLastError();
                if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
                    continue;
                } else {
                    APP_ERROR("Cannot access the directory (%lu)", GetLastError());
                    LocalFree(path);
                    return false;
                }
            }
        }
    }

    for (; p < end; p++) {
        if (*p == '\0') {
            *p = PATH_SEPARATOR;

            DEBUG("CreateDirectory(%s)", path);

            if (!CreateDirectory(path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
                APP_ERROR("Failed to create directory (%lu)", GetLastError());
                LocalFree(path);
                return false;
            }
        }
    }

    LocalFree(path);
    return true;
}

// Creates all necessary parent directories for a given file path.
bool CreateParentDirectories(const char *file)
{
    if (file == NULL || *file == '\0') {
        APP_ERROR("file is null or empty");
        return false;
    }

    size_t i = strlen(file);
    for (; i > 0; i--) { if (file[i] == PATH_SEPARATOR) break; }
    if (i == 0) { return true; }

    char *dir = (char *)LocalAlloc(LPTR, i + 1);
    if (dir == NULL) {
        APP_ERROR("LocalAlloc failed (%lu)", GetLastError());
        return false;
    }

    strncpy(dir, file, i);
    dir[i] = '\0';
    bool result = CreateDirectoriesRecursively(dir);

    LocalFree(dir);
    return result;
}

// Deletes a directory and all its contents recursively.
bool DeleteRecursively(const char *path)
{
    if (path == NULL || *path == '\0') {
        APP_ERROR("path is null or empty");
        return false;
    }

    char *findPath = JoinPath(path, "*");
    if (findPath == NULL) {
        APP_ERROR("Failed to build find path for deletion");
        return false;
    }

    WIN32_FIND_DATA findData;
    HANDLE handle = FindFirstFile(findPath, &findData);
    if (handle != INVALID_HANDLE_VALUE) {
        do {
            if ((strcmp(findData.cFileName, ".") == 0) || (strcmp(findData.cFileName, "..") == 0)) {
                continue;
            }

            char *subPath = JoinPath(path, findData.cFileName);
            if (subPath == NULL) {
                APP_ERROR("Failed to build delete file path");
                break;
            }

            if (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                DeleteRecursively(subPath);
            } else {
                if (!DeleteFile(subPath)) {
                    APP_ERROR("Failed to delete file (%lu)", GetLastError());
                    MoveFileEx(subPath, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
                }
            }

            LocalFree(subPath);
        } while (FindNextFile(handle, &findData));
        FindClose(handle);
    }
    LocalFree(findPath);

    if (!RemoveDirectory(path)) {
        APP_ERROR("Failed to delete directory (%lu)", GetLastError());
        MoveFileEx(path, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
        return false;
    } else {
        return true;
    }
}

char *GenerateUniqueName(const char *prefix)
{
    size_t prefix_len = 0;
    if (prefix != NULL) { prefix_len = strlen(prefix); }

    char *name = (char *)LocalAlloc(LPTR, prefix_len + UID_LENGTH + 1);
    if (name == NULL) {
        APP_ERROR("Failed to allocate memory for unique name (%lu)", GetLastError());
        return NULL;
    }

    LARGE_INTEGER time;
    // This function always succeeds on Windows XP and later
    QueryPerformanceCounter(&time);
    unsigned long long timestamp = time.QuadPart;
    char hex[] = "0123456789ABCDEF";
    char t[UID_LENGTH + 1];
    for (int i = 0; i < UID_LENGTH; i++) {
        t[i] = hex[(timestamp >> (4 * (UID_LENGTH - 1 - i))) & 0xF];
    }
    t[UID_LENGTH] = '\0';

    strcpy(name, prefix);
    strcat(name, t);
    return name;
}

// Generates a unique directory within a specified base path using a prefix.
char *CreateUniqueDirectory(const char *base_path, const char *prefix)
{
    if (base_path == NULL) {
        APP_ERROR("base path is null");
        return NULL;
    }

    unsigned int retry_limit = MAX_RETRY_CREATE_UNIQUE_DIR;
    for (unsigned int retry = 0; retry < retry_limit; retry++) {
        char *temp_name = GenerateUniqueName(prefix);
        if (temp_name == NULL) {
            APP_ERROR("Failed to generate a unique name");
            return NULL;
        }

        char *full_path = JoinPath(base_path, temp_name);
        LocalFree(temp_name);
        if (full_path == NULL) {
            APP_ERROR("Failed to construct a unique directory path");
            return NULL;
        }

        if (CreateDirectory(full_path, NULL)) {
            return full_path;
        } else if (GetLastError() != ERROR_ALREADY_EXISTS) {
            APP_ERROR("Failed to create a unique directory (%lu)", GetLastError());
            LocalFree(full_path);
            return NULL;
        } else {
            LocalFree(full_path);
        }

        Sleep(10); // To avoid sequential generation and prevent name duplication.
    }

    APP_ERROR("Failed to create a unique directory after %u retries", retry_limit);
    return NULL;
}

// Retrieves the full path to the executable file of the current process
char *GetImagePath(void)
{
    /*
       Note: This implementation supports long path names up to the maximum total path length
       of 32,767 characters, as permitted by Windows when the longPathAware setting is enabled.
       For more information, see the documentation on maximum file path limitations:
       https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation
    */
    DWORD buffer_size = 32767;
    wchar_t *image_path_w = (wchar_t *)LocalAlloc(LPTR, buffer_size * sizeof(wchar_t));
    if (image_path_w == NULL) {
        APP_ERROR("Failed to allocate buffer for image path (%lu)", GetLastError());
        return NULL;
    }

    DWORD copied = GetModuleFileNameW(NULL, image_path_w, buffer_size);
    if (copied == 0 || GetLastError() == ERROR_INSUFFICIENT_BUFFER) {
        APP_ERROR("Failed to get image path (%lu)", GetLastError());
        LocalFree(image_path_w);
        return NULL;
    }

    int utf8_size = WideCharToMultiByte(CP_UTF8, 0, image_path_w, -1, NULL, 0, NULL, NULL);
    if (utf8_size == 0) {
        APP_ERROR("Failed to calculate buffer size for UTF-8 conversion (%lu)", GetLastError());
        LocalFree(image_path_w);
        return NULL;
    }

    char *image_path_utf8 = (char *)LocalAlloc(LPTR, utf8_size);
    if (image_path_utf8 == NULL) {
        APP_ERROR("Failed to allocate buffer for UTF-8 image path (%lu)", GetLastError());
        LocalFree(image_path_w);
        return NULL;
    }

    if (WideCharToMultiByte(CP_UTF8, 0, image_path_w, -1, image_path_utf8, utf8_size, NULL, NULL) == 0) {
        APP_ERROR("Failed to convert image path to UTF-8 (%lu)", GetLastError());
        LocalFree(image_path_w);
        LocalFree(image_path_utf8);
        return NULL;
    }

    LocalFree(image_path_w);
    return image_path_utf8;
}

// Retrieves the directory path of the executable file of the current process.
char *GetImageDirectoryPath(void) {
    char *image_path = GetImagePath();
    if (image_path == NULL) {
        APP_ERROR("Failed to get executable name (%lu)", GetLastError());
        return NULL;
    }

    size_t i = strlen(image_path);
    for (; i > 0; i--) {
        if (image_path[i - 1] == PATH_SEPARATOR) {
            image_path[i - 1] = '\0';
            break;
        }
    }

    if (i == 0) {
        APP_ERROR("Executable path does not contain a directory");
        LocalFree(image_path);
        return NULL;
    }

    return image_path;
}

// Retrieves the path to the temporary directory for the current user.
char *GetTempDirectoryPath(void)
{
    char *temp_dir = (char *)LocalAlloc(LPTR, MAX_PATH);

    if (temp_dir == NULL) {
        APP_ERROR("Failed to memory allocate for get temp directory (%lu)", GetLastError());
        return NULL;
    }

    if (!GetTempPath(MAX_PATH, temp_dir)) {
        APP_ERROR("Failed to get temp path (%lu)", GetLastError());
        LocalFree(temp_dir);
        return NULL;
    }

    return temp_dir;
}

// Checks if the given path string is free of relative path elements.
bool IsPathFreeOfDotElements(const char *str)
{
    const char *pos = str;
    if ((pos[0] == '.' && (pos[1] == PATH_SEPARATOR || pos[1] == '\0')) ||
        (pos[0] == '.' && pos[1] == '.' && (pos[2] == PATH_SEPARATOR || pos[2] == '\0'))) {
        return false; // Path starts with './' or '../'
    }

    while ((pos = strstr(pos, ".")) != NULL) {
        if ((pos == str || *(pos - 1) == PATH_SEPARATOR) &&
            (pos[1] == PATH_SEPARATOR || pos[1] == '\0' ||
            (pos[1] == '.' && (pos[2] == PATH_SEPARATOR || pos[2] == '\0')))) {
            return false; // Found '/./', '/../', or 'dir/.' in the path
        }
        pos++;
    }

    return true;
}

// Moves the application to a safe directory.
bool ChangeDirectoryToSafeDirectory(void)
{
    char *working_dir = GetTempDirectoryPath();
    bool changed = working_dir && SetCurrentDirectory(working_dir);
    LocalFree(working_dir);

    if (changed) return true;

    DEBUG("Failed to change to temporary directory. Trying executable's directory");
    working_dir = GetImageDirectoryPath();
    changed = working_dir && SetCurrentDirectory(working_dir);
    LocalFree(working_dir);

    if (!changed) {
        APP_ERROR("Failed to change to executable's directory");
    }

    return changed;
}

typedef struct MappedFileHandle {
    HANDLE hFile;
    HANDLE hMapping;
    LPVOID lpBaseAddress;
} MappedFileHandle;

// Opens a file and maps it into the memory.
MappedFile OpenAndMapFile(const char *file_path, unsigned long long *file_size, const void **mapped_base)
{
    HANDLE hFile = CreateFile(file_path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (hFile == INVALID_HANDLE_VALUE) {
        APP_ERROR("Failed to open file (%lu)", GetLastError());
        return NULL;
    }

    LARGE_INTEGER fileSize;
    if (!GetFileSizeEx(hFile, &fileSize)) {
        APP_ERROR("Failed to get file size (%lu)", GetLastError());
        CloseHandle(hFile);
        return NULL;
    }

    if (file_size) {
        *file_size = (unsigned long long)fileSize.QuadPart;
    }

    HANDLE hMapping = CreateFileMapping(hFile, NULL, PAGE_READONLY, 0, 0, NULL);
    if (hMapping == INVALID_HANDLE_VALUE) {
        APP_ERROR("Failed to create file mapping (%lu)", GetLastError());
        CloseHandle(hFile);
        return NULL;
    }

    LPVOID lpBaseAddress = MapViewOfFile(hMapping, FILE_MAP_READ, 0, 0, 0);
    if (lpBaseAddress == NULL) {
        APP_ERROR("Failed to map view of file into memory (%lu)", GetLastError());
        CloseHandle(hMapping);
        CloseHandle(hFile);
        return NULL;
    }

    MappedFileHandle *handle = (MappedFileHandle *)LocalAlloc(LPTR, sizeof(MappedFileHandle));
    if (handle) {
        handle->hFile = hFile;
        handle->hMapping = hMapping;
        handle->lpBaseAddress = lpBaseAddress;
        if (mapped_base) {
            *mapped_base = lpBaseAddress;
        }
        return (MappedFile)handle;
    } else {
        APP_ERROR("Failed to allocate memory for handle (%lu)", GetLastError());
        UnmapViewOfFile(lpBaseAddress);
        CloseHandle(hMapping);
        CloseHandle(hFile);
        return NULL;
    }
}

// Frees a MappedFile handle and its associated resources.
bool FreeMappedFile(MappedFile handle) {
    MappedFileHandle *h = (MappedFileHandle *)handle;
    bool success = true;

    if (h != NULL) {
        if (h->lpBaseAddress != NULL) {
            if (!UnmapViewOfFile(h->lpBaseAddress)) {
                APP_ERROR("Failed to unmap view of file (%lu)", GetLastError());
                success = false;
            }
        }

        if (h->hMapping != INVALID_HANDLE_VALUE) {
            if (!CloseHandle(h->hMapping)) {
                APP_ERROR("Failed to close file mapping (%lu)", GetLastError());
                success = false;
            }
        }

        if (h->hFile != INVALID_HANDLE_VALUE) {
            if (!CloseHandle(h->hFile)) {
                APP_ERROR("Failed to close file (%lu)", GetLastError());
                success = false;
            }
        }

        LocalFree(h);
    }

    return success;
}
