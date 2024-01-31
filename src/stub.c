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
ULONGLONG GetDecompressionSize(LPVOID src);
BOOL DecompressLzma(LPVOID DecompressedData, SIZE_T unpackSize, LPVOID p, SIZE_T CompressedSize);
#endif

char *Script_ApplicationName = NULL;
char *Script_CommandLine = NULL;

BOOL DebugModeEnabled = FALSE;
BOOL DeleteInstDirEnabled = FALSE;
BOOL ChdirBeforeRunEnabled = TRUE;

void PrintFatalMessage(char *format, ...)
{
#if _CONSOLE
    fprintf_s(stderr, "FATAL ERROR: ");
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
#define LAST_ERROR(msg) fprintf_s(stderr, "FATAL ERROR: %s (error %lu)\n", msg, GetLastError());

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
    if (rel_path == NULL)
        return NULL;

    SIZE_T rel_path_len = strlen(rel_path);

    if (rel_path_len == 0)
        return NULL;

    SIZE_T len = strlen(InstDir) + 1 + rel_path_len + 1;
    char *path = (char *)LocalAlloc(LPTR, len);

    if (path == NULL) {
        LAST_ERROR("LocalAlloc failed");
        return NULL;
    }

    strcat(path, InstDir);
    strcat(path, "\\");
    strcat(path, rel_path);

    return path;
}

BOOL CheckInstDirPathExists(char *rel_path)
{
    char *path = ExpandInstDirPath(rel_path);
    BOOL result = (GetFileAttributes(path) != INVALID_FILE_ATTRIBUTES);
    LocalFree(path);

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
    SIZE_T pathLen = strlen(path);
    SIZE_T findPathLen = strlen(path) + 2 + 1; // Including places where '\*' is appended.
    char *findPath = (char *)LocalAlloc(LPTR, findPathLen);

    if (findPath == NULL) {
        LAST_ERROR("LocalAlloc failed");
        return FALSE;
    }

    strcpy(findPath, path);

    if (path[pathLen-1] == '\\')
        strcat(findPath, "*");
    else
        strcat(findPath, "\\*");

    WIN32_FIND_DATA findData;
    HANDLE handle = FindFirstFile(findPath, &findData);

    if (handle != INVALID_HANDLE_VALUE) {
        do {
            if ((strcmp(findData.cFileName, ".") == 0) || (strcmp(findData.cFileName, "..") == 0))
                continue;

            SIZE_T subPathLen = pathLen + 1 + strlen(findData.cFileName) + 1;
            char *subPath = (char *)LocalAlloc(LPTR, subPathLen);

            if (subPath == NULL) {
                LAST_ERROR("LocalAlloc failed");
                break;
            }

            strcpy(subPath, path);
            strcat(subPath, "\\");
            strcat(subPath, findData.cFileName);

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
    SIZE_T maker_len = strlen(InstDir) + 1 + strlen(DELETION_MAKER_SUFFIX) + 1;
    char *marker = (char *)LocalAlloc(LPTR, maker_len);

    if (marker == NULL) {
        LAST_ERROR("LocalAlloc failed");
        return;
    }

    strcpy(marker, InstDir);
    strcat(marker, DELETION_MAKER_SUFFIX);

    HANDLE h = CreateFile(marker, 0, 0, NULL, CREATE_ALWAYS, 0, NULL);

    if (h == INVALID_HANDLE_VALUE)
        LAST_ERROR("Failed to mark for deletion");

    CloseHandle(h);
    LocalFree(marker);
}

BOOL CreateInstDirectory(BOOL DebugExtractMode)
{
   /* Create an installation directory that will hold the extracted files */
   char TempPath[MAX_PATH];
   if (DebugExtractMode)
   {
      // In debug extraction mode, create the temp directory next to the exe
      strcpy(TempPath, InstDir);
      if (strlen(TempPath) == 0)
      {
         FATAL("Unable to find directory containing exe");
         return FALSE;
      }
   }
   else
   {
      GetTempPath(MAX_PATH, TempPath);
   }

   while (TRUE)
   {
      UINT tempResult = GetTempFileName(TempPath, "ocranstub", 0, InstDir);
      if (tempResult == 0u)
      {
         FATAL("Failed to get temp file name.");
         return FALSE;
      }

      DEBUG("Creating installation directory: '%s'", InstDir);

      /* Attempt to delete the temp file created by GetTempFileName.
         Ignore errors, i.e. if it doesn't exist. */
      (void)DeleteFile(InstDir);

      if (CreateDirectory(InstDir, NULL))
      {
         break;
      }
      else if (GetLastError() != ERROR_ALREADY_EXISTS)
      {
         FATAL("Failed to create installation directory.");
         return FALSE;
      }
   }
   return TRUE;
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
   if (lpv == NULL)
   {
      LAST_ERROR("Failed to map view of executable into memory");
   }
   else
   {
      if (!ProcessImage(lpv, FileSize))
      {
         exit_code = -1;
      }

      if (!UnmapViewOfFile(lpv))
      {
         LAST_ERROR("Failed to unmap view of executable");
      }
   }

   if (!CloseHandle(hMem))
   {
      LAST_ERROR("Failed to close file mapping");
   }

   if (!CloseHandle(hImage))
   {
      LAST_ERROR("Failed to close executable");
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

   ExitProcess(exit_code);

   /* Never gets here */
   return 0;
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

    CreateInstDirectory(debug_extract);

    BOOL last_opcode;

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

    for (p = str; *p; p++)  {
        if (*p == PLACEHOLDER) {
            strcat(out_p, InstDir);
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
    if (file_name == NULL) {
        FATAL("file_name is NULL");
        return FALSE;
    }

    char *path = ExpandInstDirPath(file_name);

    if (path == NULL) {
        FATAL("Failed to expand path to installation directory");
        return FALSE;
    }

    DEBUG("CreateFile(%s)", path);

    char parent[MAX_PATH];

    if (ParentDirectoryPath(parent, sizeof(parent), file_name)) {
        if (!MakeDirectory(parent)) {
            FATAL("Failed to create parent directory");
            LocalFree(path);
            return FALSE;
        }
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
BOOL MakeDirectory(char *DirectoryName)
{
    char *dir = ExpandInstDirPath(DirectoryName);

    if (dir == NULL)
        return FALSE;

    DEBUG("CreateDirectory(%s)", dir);

    if (CreateDirectory(dir, NULL)) {
        LocalFree(dir);
        return TRUE;
    }

    DWORD e = GetLastError();

    if (e == ERROR_ALREADY_EXISTS) {
        DEBUG("Directory already exists");
        LocalFree(dir);
        return TRUE;
    }

    if (e == ERROR_PATH_NOT_FOUND) {
        char parent[MAX_PATH];

        if (ParentDirectoryPath(parent, sizeof(parent), DirectoryName))
            if (MakeDirectory(parent))
                if (CreateDirectory(dir, NULL)) {
                    LocalFree(dir);
                    return TRUE;
                }
    }

    FATAL("Failed to create directory '%s'.", dir);

    LocalFree(dir);
    return FALSE;
}

void GetScriptInfo(char *ImageName, char **pApplicationName, char *CmdLine, char **pCommandLine)
{
   *pApplicationName = ReplaceInstDirPlaceholder(ImageName);

   char *ExpandedCommandLine = ReplaceInstDirPlaceholder(CmdLine);
   char *MyCmdLine = GetCommandLine();
   char *MyArgs = SkipArg(MyCmdLine);

   *pCommandLine = LocalAlloc(LMEM_FIXED, strlen(ExpandedCommandLine) + 1 + strlen(MyArgs) + 1);
   strcpy(*pCommandLine, ExpandedCommandLine);
   strcat(*pCommandLine, " ");
   strcat(*pCommandLine, MyArgs);

   LocalFree(ExpandedCommandLine);
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
   }

   CloseHandle(ProcessInformation.hProcess);
   CloseHandle(ProcessInformation.hThread);
   return exit_code;
}

/**
 * Sets up a process to be created after all other opcodes have been processed. This can be used to create processes
 * after the temporary files have all been created and memory has been freed.
 */
BOOL SetScript(char *app_name, char *cmd_line)
{
    DEBUG("SetScript");
    if (Script_ApplicationName || Script_CommandLine) {
        FATAL("Script is already set");
        return FALSE;
    }

    GetScriptInfo(app_name, &Script_ApplicationName, cmd_line, &Script_CommandLine);

    return TRUE;
}

#if WITH_LZMA
void* SzAlloc(void* p, size_t size) { p = p; return LocalAlloc(LMEM_FIXED, size); }
void SzFree(void* p, void* address) { p = p; LocalFree(address); }
ISzAlloc alloc = { SzAlloc, SzFree };

#define LZMA_UNPACKSIZE_SIZE 8
#define LZMA_HEADER_SIZE (LZMA_PROPS_SIZE + LZMA_UNPACKSIZE_SIZE)

ULONGLONG GetDecompressionSize(LPVOID src)
{
    ULONGLONG size = 0;

    for (int i = 0; i < LZMA_UNPACKSIZE_SIZE; i++)
        size += ((LPBYTE)src)[LZMA_PROPS_SIZE + i] << (i * 8);

    return size;
}

BOOL DecompressLzma(LPVOID DecompressedData, SIZE_T unpackSize, LPVOID p, SIZE_T CompressedSize)
{
   Byte* src = (Byte*)p;
   SizeT lzmaDecompressedSize = unpackSize;
   SizeT inSizePure = CompressedSize - LZMA_HEADER_SIZE;
   ELzmaStatus status;
   SRes res = LzmaDecode(DecompressedData, &lzmaDecompressedSize, src + LZMA_HEADER_SIZE, &inSizePure,
                         src, LZMA_PROPS_SIZE, LZMA_FINISH_ANY, &status, &alloc);

   return (BOOL)(res == SZ_OK);
}
#endif

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
