/*
  Single Executable Bundle Stub
  This stub reads itself for embedded instructions to create directory
  and files in a temporary directory, launching a program.
*/

#include <windows.h>
#include <string.h>
#include <stdio.h>
#include "unpack.h"

const BYTE Signature[] = { 0x41, 0xb6, 0xba, 0x4e };

BOOL ProcessImage(LPVOID p, DWORD size);
DWORD CreateAndWaitForProcess(char *ApplicationName, char *CommandLine);

#if WITH_LZMA
#include <LzmaDec.h>

#define LZMA_UNPACKSIZE_SIZE 8

ULONGLONG GetDecompressionSize(void *src)
{
    ULONGLONG size = 0;

    for (int i = 0; i < LZMA_UNPACKSIZE_SIZE; i++)
        size += ((BYTE *)src)[LZMA_PROPS_SIZE + i] << (i * 8);

    return size;
}

#define LZMA_HEADER_SIZE (LZMA_PROPS_SIZE + LZMA_UNPACKSIZE_SIZE)

void *SzAlloc(const ISzAlloc *p, size_t size) { p = p; return LocalAlloc(LMEM_FIXED, size); }
void SzFree(const ISzAlloc *p, void *address) { p = p; LocalFree(address); }
ISzAlloc alloc = { SzAlloc, SzFree };

BOOL DecompressLzma(void *unpack_data, size_t unpack_size, void *src, size_t src_size)
{
    SizeT lzmaDecompressedSize = unpack_size;
    SizeT inSizePure = src_size - LZMA_HEADER_SIZE;
    ELzmaStatus status;

    SRes res = LzmaDecode((Byte *)unpack_data, &lzmaDecompressedSize, (Byte *)src + LZMA_HEADER_SIZE, &inSizePure,
                          (Byte *)src, LZMA_PROPS_SIZE, LZMA_FINISH_ANY, &status, &alloc);

    return (BOOL)(res == SZ_OK);
}
#endif

char *Script_ApplicationName = NULL;
char *Script_CommandLine = NULL;

BOOL DebugModeEnabled = FALSE;
BOOL DeleteInstDirEnabled = FALSE;
BOOL ChdirBeforeRunEnabled = TRUE;

void PrintFatalMessage(char *format, ...)
{
#if _CONSOLE
    fprintf_s(stderr, "FATAL: ");
    va_list args;
    va_start(args, format);
    vfprintf_s(stderr, format, args);
    va_end(args);
    fprintf_s(stderr, "\n");
#else
    char TextBuffer[1024];
    va_list args;
    va_start(args, format);
    snprintf(TextBuffer, 1024, format, args);
    va_end(args);
    MessageBox(NULL, TextBuffer, "OCRAN", MB_OK | MB_ICONWARNING);
#endif
}

#define FATAL(...) PrintFatalMessage(__VA_ARGS__)

void PrintLastError(char *msg) {
    fprintf_s(stderr, "ERROR: %s (%lu)\n", msg, GetLastError());
}

#define LAST_ERROR(msg) PrintLastError(msg)

void PrintDebugMessage(char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf_s(stderr, format, args);
    va_end(args);
    fprintf_s(stderr, "\n");
}

#if _CONSOLE
#define DEBUG(...) { if (DebugModeEnabled) PrintDebugMessage(__VA_ARGS__); }
#else
#define DEBUG(...)
#endif

char InstDir[MAX_PATH];

char* ConcatStr(const char *first, ...) {
    va_list args;
    va_start(args, first);
    size_t len = 0;
    for (const char* s = first; s; s = va_arg(args, const char*)) {
        len += strlen(s);
    }
    va_end(args);

    char *str = LocalAlloc(LPTR, len + 1);

    if (str == NULL) {
        LAST_ERROR("Failed to allocate memory");
        return NULL;
    }

    va_start(args, first);
    char *p = str;
    for (const char *s = first; s; s = va_arg(args, const char*)) {
        size_t l = strlen(s);
        memcpy(p, s, l);
        p += l;
    }
    str[len] = '\0';
    va_end(args);

    return str;
}

char *JoinPath(const char *p1, const char *p2)
{
    if (p1 == NULL || *p1 == '\0') {
        DEBUG("p1 is null or empty");
        return NULL;
    }

    if (p2 == NULL || *p2 == '\0') {
        DEBUG("p2 is null or empty");
        return NULL;
    }

    // If p2 starts with a file path separator, skip it.
    if (p2[0] == '\\') p2++;

    // If p1 doesn't end with a file path separator, add the separator and concatenate.
    if (p1[strlen(p1) - 1] != '\\')
        return ConcatStr(p1, "\\", p2, NULL);
    else
        return ConcatStr(p1, p2, NULL);
}

SIZE_T ParentDirectoryPath(char *dest, SIZE_T dest_len, char *path)
{
    if (path == NULL) return 0;

    SIZE_T i = strlen(path);

    for (; i > 0; i--)
        if (path[i] == '\\') break;

    if (dest != NULL)
        if (strncpy_s(dest, dest_len, path, i))
            return 0;

    return i;
}

char *ExpandInstDirPath(char *rel_path)
{
    if (rel_path == NULL || *rel_path == '\0') {
        DEBUG("rel_path is null or empty");
        return NULL;
    }

    return JoinPath(InstDir, rel_path);
}

BOOL CheckInstDirPathExists(char *rel_path)
{
    char *path = ExpandInstDirPath(rel_path);
    BOOL result = (GetFileAttributes(path) != INVALID_FILE_ATTRIBUTES);
    LocalFree(path);

    return result;
}

BOOL CreateDirectoriesRecursively(const char *dir)
{
    if (dir == NULL || *dir == '\0') {
        DEBUG("dir is null or empty");
        return FALSE;
    }

    DWORD dir_attr = GetFileAttributes(dir);

    if (dir_attr != INVALID_FILE_ATTRIBUTES) {
        if (dir_attr & FILE_ATTRIBUTE_DIRECTORY) {
            return TRUE;
        } else {
            FATAL("Directory name conflicts with a file(%s)", dir);
            return FALSE;
        }
    }

    size_t dir_len = strlen(dir);
    char *path = (char *)LocalAlloc(LPTR, dir_len + 1);

    if (path == NULL) {
        FATAL("LocalAlloc failed");
        return FALSE;
    }

    strcpy(path, dir);

    char *end = path + dir_len;
    char *p = end;

    for (; p >= path; p--) {
        if (*p == '\\') {
            *p = '\0';

            DWORD path_attr = GetFileAttributes(path);

            if (path_attr != INVALID_FILE_ATTRIBUTES) {
                if (path_attr & FILE_ATTRIBUTE_DIRECTORY) {
                    break;
                } else {
                    FATAL("Directory name conflicts with a file(%s)", path);
                    LocalFree(path);
                    return FALSE;
                }
            } else {
                DWORD error = GetLastError();

                if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
                    continue;
                } else {
                    LAST_ERROR("Cannot access the directory");
                    LocalFree(path);
                    return FALSE;
                }
            }
        }
    }

    for (; p < end; p++) {
        if (*p == '\0') {
            *p = '\\';

            DEBUG("CreateDirectory(%s)", path);

            if (!CreateDirectory(path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
                LAST_ERROR("Failed to create directory");
                LocalFree(path);
                return FALSE;
            }
        }
    }

    LocalFree(path);
    return TRUE;
}

BOOL CreateParentDirectories(const char *file)
{
    if (file == NULL || *file == '\0') {
        FATAL("file is null or empty");
        return FALSE;
    }

    size_t i = strlen(file);

    for (; i > 0; i--)
        if (file[i] == '\\') break;

    if (i == 0)
        return TRUE;

    char *dir = (char *)LocalAlloc(LPTR, i + 1);

    if (dir == NULL) {
        FATAL("LocalAlloc failed");
        return FALSE;
    }

    strncpy(dir, file, i);
    dir[i] = '\0';

    BOOL result = CreateDirectoriesRecursively(dir);

    LocalFree(dir);
    return result;
}

/**
   Handler for console events.
*/
BOOL WINAPI ConsoleHandleRoutine(DWORD dwCtrlType)
{
   // Ignore all events. They will also be dispatched to the child procress (Ruby) which should
   // exit quickly, allowing us to clean up.
   return TRUE;
}

BOOL DeleteRecursively(char *path)
{
    char *findPath = JoinPath(path, "*");

    if (findPath == NULL) {
        FATAL("Failed to build find path for deletion");
        return FALSE;
    }

    WIN32_FIND_DATA findData;
    HANDLE handle = FindFirstFile(findPath, &findData);

    if (handle != INVALID_HANDLE_VALUE) {
        do {
            if ((strcmp(findData.cFileName, ".") == 0) || (strcmp(findData.cFileName, "..") == 0))
                continue;

            char *subPath = JoinPath(path, findData.cFileName);

            if (subPath == NULL) {
                FATAL("Failed to build delete file path");
                break;
            }

            if (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                DeleteRecursively(subPath);
            } else {
                if (!DeleteFile(subPath)) {
                    LAST_ERROR("Failed to delete file");
                    MoveFileEx(subPath, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
                }
            }

            LocalFree(subPath);
        } while (FindNextFile(handle, &findData));
        FindClose(handle);
    }

    LocalFree(findPath);

    if (!RemoveDirectory(path)) {
        LAST_ERROR("Failed to delete directory");
        MoveFileEx(path, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
        return FALSE;
    } else {
        return TRUE;
    }
}

#define DELETION_MAKER_SUFFIX ".ocran-delete-me"

void MarkInstDirForDeletion(void)
{
    char *marker = ConcatStr(InstDir, DELETION_MAKER_SUFFIX, NULL);

    if (marker == NULL)
        return;

    HANDLE h = CreateFile(marker, 0, 0, NULL, CREATE_ALWAYS, 0, NULL);

    if (h == INVALID_HANDLE_VALUE)
        LAST_ERROR("Failed to mark for deletion");

    CloseHandle(h);
    LocalFree(marker);
}

BOOL CreateInstDirectory(BOOL debug_extract)
{
    /* Create an installation directory that will hold the extracted files */
    char temp_path[MAX_PATH];

    if (debug_extract) {
        // In debug extraction mode, create the temp directory next to the exe
        strcpy(temp_path, InstDir);

        if (strlen(temp_path) == 0) {
            FATAL("Unable to find directory containing exe");
            return FALSE;
        }
    } else {
        if (!GetTempPath(MAX_PATH, temp_path)) {
            LAST_ERROR("Failed to get temp path");
            return FALSE;
        }
    }

    while (TRUE) {
        if (!GetTempFileName(temp_path, "ocran", 0, InstDir)) {
            LAST_ERROR("Failed to get temp file name");
            return FALSE;
        }

        DEBUG("Creating installation directory: %s", InstDir);

        /* Attempt to delete the temp file created by GetTempFileName.
           Ignore errors, i.e. if it doesn't exist. */
        (void)DeleteFile(InstDir);

        if (CreateDirectory(InstDir, NULL)) {
            return TRUE;
        } else if (GetLastError() != ERROR_ALREADY_EXISTS) {
            LAST_ERROR("Failed to create installation directory");
            return FALSE;
        }
    }
}

int CALLBACK WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
    DWORD exit_code = 0;
    char image_path[MAX_PATH];

   /* Find name of image */
   if (!GetModuleFileName(NULL, image_path, MAX_PATH))
   {
      LAST_ERROR("Failed to get executable name");
      return -1;
   }


    /* By default, assume the installation directory is wherever the EXE is */
    if (!ParentDirectoryPath(InstDir, sizeof(InstDir), image_path)) {
        FATAL("Failed to set default installation directory.");
        return -1;
    }

   SetConsoleCtrlHandler(&ConsoleHandleRoutine, TRUE);

   /* Open the image (executable) */
   HANDLE hImage = CreateFile(image_path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
   if (hImage == INVALID_HANDLE_VALUE)
   {
      FATAL("Failed to open executable (%s)", image_path);
      return -1;
   }

   /* Create a file mapping */
   DWORD FileSize = GetFileSize(hImage, NULL);
   HANDLE hMem = CreateFileMapping(hImage, NULL, PAGE_READONLY, 0, FileSize, NULL);
   if (hMem == INVALID_HANDLE_VALUE)
   {
      LAST_ERROR("Failed to create file mapping");
      CloseHandle(hImage);
      return -1;
   }

    /* Map the image into memory */
    LPVOID lpv = MapViewOfFile(hMem, FILE_MAP_READ, 0, 0, 0);
    if (lpv == NULL) {
        LAST_ERROR("Failed to map view of executable into memory");
        return -1;
    }

    if (!ProcessImage(lpv, FileSize)) {
        exit_code = -1;
    }

    if (!UnmapViewOfFile(lpv)) {
        LAST_ERROR("Failed to unmap view of executable");
        exit_code = -1;
    }

    if (!CloseHandle(hMem)) {
        LAST_ERROR("Failed to close file mapping");
        exit_code = -1;
    }

    if (!CloseHandle(hImage)) {
        LAST_ERROR("Failed to close executable");
        exit_code = -1;
    }

    if (exit_code == 0 && Script_ApplicationName && Script_CommandLine) {
        DEBUG("*** Starting app in %s", InstDir);

        if (ChdirBeforeRunEnabled) {
            DEBUG("Changing CWD to unpacked directory %s/src", InstDir);

            char *script_dir = ExpandInstDirPath("src");

            if (!SetCurrentDirectory(script_dir)) {
                LAST_ERROR("Failed to change CWD");
                exit_code = -1;
            }

            LocalFree(script_dir);
        }

        if (exit_code == 0) {
            if (!SetEnvironmentVariable("OCRAN_EXECUTABLE", image_path)) {
                LAST_ERROR("Failed to set environment variable");
                exit_code = -1;
            } else {
                exit_code = CreateAndWaitForProcess(Script_ApplicationName, Script_CommandLine);
            }
        }
    }

    LocalFree(Script_ApplicationName);
    Script_ApplicationName = NULL;

    LocalFree(Script_CommandLine);
    Script_CommandLine = NULL;

   if (DeleteInstDirEnabled)
   {
      DEBUG("Deleting temporary installation directory %s", InstDir);
      char SystemDirectory[MAX_PATH];
      if (GetSystemDirectory(SystemDirectory, MAX_PATH) > 0)
         SetCurrentDirectory(SystemDirectory);
      else
         SetCurrentDirectory("C:\\");

      if (!DeleteRecursively(InstDir))
            MarkInstDirForDeletion();
   }

    return exit_code;
}

/**
   Process the image by checking the signature and locating the first
   opcode.
*/
BOOL ProcessImage(LPVOID ptr, DWORD size)
{
    LPVOID pSig = ptr + size - sizeof(Signature);
    if (memcmp(pSig, Signature, sizeof(Signature)) != 0) {
        FATAL("Bad signature in executable.");
        return FALSE;
    }
    DEBUG("Good signature found.");

    LPVOID data_tail = pSig - sizeof(DWORD);
    DWORD OpcodeOffset = *(DWORD*)(data_tail);
    LPVOID pSeg = ptr + OpcodeOffset;

    DebugModeEnabled      = (BOOL)*(LPBYTE)pSeg; pSeg++;
    BOOL debug_extract    = (BOOL)*(LPBYTE)pSeg; pSeg++;
    DeleteInstDirEnabled  = (BOOL)*(LPBYTE)pSeg; pSeg++;
    ChdirBeforeRunEnabled = (BOOL)*(LPBYTE)pSeg; pSeg++;
    BOOL compressed       = (BOOL)*(LPBYTE)pSeg; pSeg++;

    if (DebugModeEnabled)
        DEBUG("Ocran stub running in debug mode");

    if (!CreateInstDirectory(debug_extract)) {
        FATAL("Failed to create installation directory");
        ExitProcess(-1);
    }

    BYTE last_opcode;

    if (compressed) {
#if WITH_LZMA
        DWORD data_len = data_tail - pSeg;
        DEBUG("LzmaDecode(%ld)", data_len);

        ULONGLONG unpack_size = GetDecompressionSize(pSeg);
        if (unpack_size > (ULONGLONG)(DWORD)-1) {
            FATAL("Decompression size is too large.");
            return FALSE;
        }

        LPVOID unpack_data = LocalAlloc(LMEM_FIXED, unpack_size);
        if (unpack_data == NULL) {
            LAST_ERROR("LocalAlloc failed");
            return FALSE;
        }

        if (!DecompressLzma(unpack_data, unpack_size, pSeg, data_len)) {
            FATAL("LZMA decompression failed.");
            LocalFree(unpack_data);
            return FALSE;
        }

        LPVOID p = unpack_data;
        last_opcode = ProcessOpcodes(&p);
        LocalFree(unpack_data);
#else
        FATAL("Does not support LZMA");
        return FALSE;
#endif
    } else {
        last_opcode = ProcessOpcodes(&pSeg);
    }

    if (last_opcode != OP_END) {
        FATAL("Invalid opcode '%u'.", last_opcode);
        return FALSE;
    }
    return TRUE;
}

/**
   Expands a specially formatted string, replacing | with the
   temporary installation directory.
*/

#define PLACEHOLDER '|'

char *ReplaceInstDirPlaceholder(char *str)
{
    int InstDirLen = strlen(InstDir);
    char *p;
    int c = 0;

    for (p = str; *p; p++) { if (*p == PLACEHOLDER) c++; }
    SIZE_T out_len = strlen(str) - c + InstDirLen * c + 1;
    char *out = (char *)LocalAlloc(LPTR, out_len);

    if (out == NULL) {
        LAST_ERROR("LocalAlloc failed");
        return NULL;
    }

    char *out_p = out;

    for (p = str; *p; p++) {
        if (*p == PLACEHOLDER) {
            memcpy(out_p, InstDir, InstDirLen);
            out_p += InstDirLen;
        } else {
            *out_p = *p;
            out_p++;
        }
    }
    *out_p = '\0';

    return out;
}

/**
   Finds the start of the first argument after the current one. Handles quoted arguments.
*/
char *SkipArg(char *str)
{
   if (*str == '"')
   {
      str++;
      while (*str && *str != '"') { str++; }
      if (*str == '"') { str++; }
   }
   else
   {
      while (*str && *str != ' ') { str++; }
   }
   while (*str && *str != ' ') { str++; }
   return str;
}

/**
   Create a file (OP_CREATE_FILE opcode handler)
*/
BOOL MakeFile(char *file_name, DWORD file_size, LPVOID data)
{
    if (file_name == NULL || *file_name == '\0') {
        FATAL("file_name is null or empty");
        return FALSE;
    }

    char *path = ExpandInstDirPath(file_name);

    if (path == NULL) {
        FATAL("Failed to expand path to installation directory");
        return FALSE;
    }

    DEBUG("CreateFile(%s)", path);

    if (!CreateParentDirectories(path)) {
        FATAL("Failed to create parent directory");
        LocalFree(path);
        return FALSE;
    }

    BOOL result = TRUE;
    HANDLE h = CreateFile(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);

    if (h != INVALID_HANDLE_VALUE) {
        DWORD BytesWritten;

        DEBUG("Write data(%lu)", file_size);

        if (!WriteFile(h, data, file_size, &BytesWritten, NULL)) {
            LAST_ERROR("Write failure");
            result = FALSE;
        }

        if (BytesWritten != file_size) {
            FATAL("Write size failure");
            result = FALSE;
        }

        CloseHandle(h);
    } else {
        LAST_ERROR("Failed to create file");
        result = FALSE;
    }

    LocalFree(path);

    return result;
}

/**
   Create a directory (OP_CREATE_DIRECTORY opcode handler)
*/
BOOL MakeDirectory(char *dir_name)
{
    DEBUG("MakeDirectory");

    if (dir_name == NULL || *dir_name == '\0') {
        DEBUG("dir_name is NULL or empty");
        return FALSE;
    }

    char *dir = ExpandInstDirPath(dir_name);

    if (dir == NULL) {
        FATAL("Failed to expand dir_name to installation directory");
        return FALSE;
    }

    BOOL result = CreateDirectoriesRecursively(dir);

    LocalFree(dir);
    return result;
}

DWORD CreateAndWaitForProcess(char *ApplicationName, char *CommandLine)
{
   PROCESS_INFORMATION ProcessInformation;
   STARTUPINFO StartupInfo;
   ZeroMemory(&StartupInfo, sizeof(StartupInfo));
   StartupInfo.cb = sizeof(StartupInfo);
   BOOL r = CreateProcess(ApplicationName, CommandLine, NULL, NULL,
                          TRUE, 0, NULL, NULL, &StartupInfo, &ProcessInformation);

   if (!r)
   {
      FATAL("Failed to create process (%s): %lu", ApplicationName, GetLastError());
      return -1;
   }

   WaitForSingleObject(ProcessInformation.hProcess, INFINITE);

   DWORD exit_code;
   if (!GetExitCodeProcess(ProcessInformation.hProcess, &exit_code))
   {
      LAST_ERROR("Failed to get exit status");
      exit_code = -1;
   }

   CloseHandle(ProcessInformation.hProcess);
   CloseHandle(ProcessInformation.hThread);
   return exit_code;
}

/**
 * Sets up a process to be created after all other opcodes have been processed. This can be used to create processes
 * after the temporary files have all been created and memory has been freed.
 */
BOOL SetScript(char *app_name, char *script_name, char *cmd_line)
{
    DEBUG("SetScript");

    if (Script_ApplicationName || Script_CommandLine) {
        FATAL("Script is already set");
        return FALSE;
    }

    // Set Script_ApplicationName

    Script_ApplicationName = ExpandInstDirPath(app_name);

    if (Script_ApplicationName == NULL) {
        FATAL("Failed to expand app_name to installation directory");
        return FALSE;
    }

    // Set Script_CommandLine

    char *arg_0 = "ruby"; // This is a dummy. Ruby will ignore this.

    char *script_path = ExpandInstDirPath(script_name);

    if (script_path == NULL) {
        FATAL("Failed to expand script_name to installation directory");
        return FALSE;
    }

    char *replaced_cmd_line = ReplaceInstDirPlaceholder(cmd_line);

    if (replaced_cmd_line == NULL) {
        FATAL("Failed to replace cmd_line placeholder");
        LocalFree(script_path);
        return FALSE;
    }

    char *MyArgs = SkipArg(GetCommandLine());

    Script_CommandLine = ConcatStr(arg_0, " \"", script_path, "\" ", replaced_cmd_line, " ", MyArgs, NULL);

    if (Script_CommandLine == NULL) {
        FATAL("Failed to build command line");
        LocalFree(script_path);
        LocalFree(replaced_cmd_line);
        return FALSE;
    }

    LocalFree(script_path);
    LocalFree(replaced_cmd_line);
    return TRUE;
}

BOOL SetEnv(char *name, char *value)
{
    char *replaced_value = ReplaceInstDirPlaceholder(value);

    if (replaced_value == NULL) {
        FATAL("Failed to replace the value placeholder");
        return FALSE;
    }

    DEBUG("SetEnv(%s, %s)", name, replaced_value);

    BOOL result = SetEnvironmentVariable(name, replaced_value);

    if (!result)
        LAST_ERROR("Failed to set environment variable");

    LocalFree(replaced_value);

    return result;
}
