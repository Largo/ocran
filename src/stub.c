/*
  Single Executable Bundle Stub
  This stub reads itself for embedded instructions to create directory
  and files in a temporary directory, launching a program.
*/

#include <windows.h>
#include <string.h>
#include <tchar.h>
#include <stdio.h>
#include "unpack.h"

const BYTE Signature[] = { 0x41, 0xb6, 0xba, 0x4e };

BOOL ProcessImage(LPVOID p, DWORD size);
DWORD CreateAndWaitForProcess(LPTSTR ApplicationName, LPTSTR CommandLine);

#if WITH_LZMA
#include <LzmaDec.h>
ULONGLONG GetDecompressionSize(LPVOID src);
BOOL DecompressLzma(LPVOID DecompressedData, SIZE_T unpackSize, LPVOID p, SIZE_T CompressedSize);
#endif

LPTSTR Script_ApplicationName = NULL;
LPTSTR Script_CommandLine = NULL;

BOOL DebugModeEnabled = FALSE;
BOOL DeleteInstDirEnabled = FALSE;
BOOL ChdirBeforeRunEnabled = TRUE;

#if _CONSOLE
#define FATAL(...) { fprintf(stderr, "FATAL ERROR: "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); }
#else
#define FATAL(...) { \
   TCHAR TextBuffer[1024]; \
   _sntprintf(TextBuffer, 1024, __VA_ARGS__); \
   MessageBox(NULL, TextBuffer, _T("OCRAN"), MB_OK | MB_ICONWARNING); \
   }
#endif

#if _CONSOLE
#define DEBUG(...) { if (DebugModeEnabled) { fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } }
#else
#define DEBUG(...)
#endif

TCHAR InstDir[MAX_PATH];

SIZE_T ParentDirectoryPath(LPTSTR dest, SIZE_T dest_len, LPTSTR path)
{
    if (path == NULL) return 0;

    SIZE_T i = lstrlen(path);

    for (; i > 0; i--)
        if (path[i] == L'\\') break;

    if (dest != NULL)
        if (_tcsncpy_s(dest, dest_len, path, i))
            return 0;

    return i;
}

BOOL CheckInstDirPathExists(LPTSTR rel_path)
{
    TCHAR path[MAX_PATH];
    lstrcpy(path, InstDir);
    lstrcat(path, _T("\\"));
    lstrcat(path, rel_path);

    return (BOOL)(GetFileAttributes(path) != INVALID_FILE_ATTRIBUTES);
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

BOOL DeleteRecursively(LPTSTR path)
{
   TCHAR findPath[MAX_PATH];
   DWORD pathLength;
   WIN32_FIND_DATA findData;
   HANDLE handle;
   BOOL AnyFailed = FALSE;

   lstrcpy(findPath, path);
   pathLength = lstrlen(findPath);
   if (pathLength > 1 && pathLength < MAX_PATH - 2) {
      if (path[pathLength-1] == '\\')
         lstrcat(findPath, "*");
      else {
         lstrcat(findPath, "\\*");
         ++pathLength;
      }
      handle = FindFirstFile(findPath, &findData);
      findPath[pathLength] = 0;
      if (handle != INVALID_HANDLE_VALUE) {
         do {
            if (pathLength + lstrlen(findData.cFileName) < MAX_PATH) {
               TCHAR subPath[MAX_PATH];
               lstrcpy(subPath, findPath);
               lstrcat(subPath, findData.cFileName);
               if ((lstrcmp(findData.cFileName, ".") != 0) && (lstrcmp(findData.cFileName, "..") != 0)) {
                  if (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                     if (!DeleteRecursively(subPath))
                        AnyFailed = TRUE;
                  } else {
                     if (!DeleteFile(subPath)) {
                        MoveFileEx(subPath, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
                        AnyFailed = TRUE;
                     }
                  }
               }
            } else {
               AnyFailed = TRUE;
            }
         } while (FindNextFile(handle, &findData));
         FindClose(handle);
      }
   } else {
      AnyFailed = TRUE;
   }
   if (!RemoveDirectory(findPath)) {
      MoveFileEx(findPath, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
      AnyFailed = TRUE;
   }
   return AnyFailed;
}

void MarkForDeletion(LPTSTR path)
{
   TCHAR marker[MAX_PATH];
   lstrcpy(marker, path);
   lstrcat(marker, ".ocran-delete-me");
   HANDLE h = CreateFile(marker, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
   CloseHandle(h);
}

BOOL CreateInstDirectory(BOOL DebugExtractMode)
{
   /* Create an installation directory that will hold the extracted files */
   TCHAR TempPath[MAX_PATH];
   if (DebugExtractMode)
   {
      // In debug extraction mode, create the temp directory next to the exe
      lstrcpy(TempPath, InstDir);
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
      UINT tempResult = GetTempFileName(TempPath, _T("ocranstub"), 0, InstDir);
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

int CALLBACK _tWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPTSTR lpCmdLine, int nCmdShow)
{
    DWORD exit_code = 0;
    TCHAR image_path[MAX_PATH];

   /* Find name of image */
   if (!GetModuleFileName(NULL, image_path, MAX_PATH))
   {
      FATAL("Failed to get executable name (error %lu).", GetLastError());
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
      FATAL("Failed to create file mapping (error %lu)", GetLastError());
      CloseHandle(hImage);
      return -1;
   }

   /* Map the image into memory */
   LPVOID lpv = MapViewOfFile(hMem, FILE_MAP_READ, 0, 0, 0);
   if (lpv == NULL)
   {
      FATAL("Failed to map view of executable into memory (error %lu).", GetLastError());
   }
   else
   {
      if (!ProcessImage(lpv, FileSize))
      {
         exit_code = -1;
      }

      if (!UnmapViewOfFile(lpv))
      {
         FATAL("Failed to unmap view of executable.");
      }
   }

   if (!CloseHandle(hMem))
   {
      FATAL("Failed to close file mapping.");
   }

   if (!CloseHandle(hImage))
   {
      FATAL("Failed to close executable.");
   }

    if (exit_code == 0 && Script_ApplicationName && Script_CommandLine) {
        DEBUG("*** Starting app in %s", InstDir);

        if (ChdirBeforeRunEnabled) {
            DEBUG("Changing CWD to unpacked directory %s/src", InstDir);
            SetCurrentDirectory(InstDir);
            SetCurrentDirectory("./src");
        }

        SetEnvironmentVariable(_T("OCRAN_EXECUTABLE"), image_path);

        exit_code = CreateAndWaitForProcess(Script_ApplicationName, Script_CommandLine);
    }

    LocalFree(Script_ApplicationName);
    Script_ApplicationName = NULL;

    LocalFree(Script_CommandLine);
    Script_CommandLine = NULL;

   if (DeleteInstDirEnabled)
   {
      DEBUG("Deleting temporary installation directory %s", InstDir);
      TCHAR SystemDirectory[MAX_PATH];
      if (GetSystemDirectory(SystemDirectory, MAX_PATH) > 0)
         SetCurrentDirectory(SystemDirectory);
      else
         SetCurrentDirectory("C:\\");

      if (!DeleteRecursively(InstDir))
            MarkForDeletion(InstDir);
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
            FATAL("LocalAlloc failed with error %lu", GetLastError());
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
LPTSTR ReplaceInstDirPlaceholder(LPTSTR str)
{
   DWORD OutSize = lstrlen(str) + 1;
   LPTSTR a = str;
   while ((a = _tcschr(a, L'|')))
   {
      OutSize += lstrlen(InstDir) - 1;
      a++;
   }

   LPTSTR out = (LPTSTR)LocalAlloc(LMEM_FIXED, OutSize);

   LPTSTR OutPtr = out;
   while ((a = _tcschr(str, L'|')))
   {
      int l = a - str;
      if (l > 0)
      {
         memcpy(OutPtr, str, l);
         OutPtr += l;
         str += l;
      }
      str += 1;
      lstrcpy(OutPtr, InstDir);
      OutPtr += lstrlen(OutPtr);
   }
   lstrcpy(OutPtr, str);
   return out;
}

/**
   Finds the start of the first argument after the current one. Handles quoted arguments.
*/
LPTSTR SkipArg(LPTSTR str)
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
BOOL MakeFile(LPTSTR FileName, DWORD FileSize, LPVOID Data)
{
   BOOL Result = TRUE;

   TCHAR Fn[MAX_PATH];
   lstrcpy(Fn, InstDir);
   lstrcat(Fn, _T("\\"));
   lstrcat(Fn, FileName);

   DEBUG("CreateFile(%s, %lu)", Fn, FileSize);

    TCHAR parent[MAX_PATH];

    if (ParentDirectoryPath(parent, sizeof(parent), FileName)) {
        if (!CheckInstDirPathExists(parent)) {
            if (!MakeDirectory(parent)) {
                FATAL("Failed to create file '%s'", Fn);
                return FALSE;
            }
        }
    }

   HANDLE hFile = CreateFile(Fn, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
   if (hFile != INVALID_HANDLE_VALUE)
   {
      DWORD BytesWritten;
      if (!WriteFile(hFile, Data, FileSize, &BytesWritten, NULL))
      {
         FATAL("Write failure (%lu)", GetLastError());
         Result = FALSE;
      }
      if (BytesWritten != FileSize)
      {
         FATAL("Write size failure");
         Result = FALSE;
      }
      CloseHandle(hFile);
   }
   else
   {
      FATAL("Failed to create file '%s'", Fn);
      Result = FALSE;
   }

   return Result;
}

/**
   Create a directory (OP_CREATE_DIRECTORY opcode handler)
*/
BOOL MakeDirectory(LPTSTR DirectoryName)
{
   TCHAR DirName[MAX_PATH];
   lstrcpy(DirName, InstDir);
   lstrcat(DirName, _T("\\"));
   lstrcat(DirName, DirectoryName);

   DEBUG("CreateDirectory(%s)", DirName);

    if (CreateDirectory(DirName, NULL))
        return TRUE;

    DWORD e = GetLastError();

    if (e == ERROR_ALREADY_EXISTS) {
        DEBUG("Directory already exists");
        return TRUE;
    }

    if (e == ERROR_PATH_NOT_FOUND) {
        TCHAR parent[MAX_PATH];

        if (ParentDirectoryPath(parent, sizeof(parent), DirectoryName))
            if (MakeDirectory(parent))
                if (CreateDirectory(DirName, NULL))
                    return TRUE;
    }

    FATAL("Failed to create directory '%s'.", DirName);

    return FALSE;
}

void GetScriptInfo(LPTSTR ImageName, LPTSTR* pApplicationName, LPTSTR CmdLine, LPTSTR* pCommandLine)
{
   *pApplicationName = ReplaceInstDirPlaceholder(ImageName);

   LPTSTR ExpandedCommandLine = ReplaceInstDirPlaceholder(CmdLine);
   LPTSTR MyCmdLine = GetCommandLine();
   LPTSTR MyArgs = SkipArg(MyCmdLine);

   *pCommandLine = LocalAlloc(LMEM_FIXED, lstrlen(ExpandedCommandLine) + 1 + lstrlen(MyArgs) + 1);
   lstrcpy(*pCommandLine, ExpandedCommandLine);
   lstrcat(*pCommandLine, _T(" "));
   lstrcat(*pCommandLine, MyArgs);

   LocalFree(ExpandedCommandLine);
}

DWORD CreateAndWaitForProcess(LPTSTR ApplicationName, LPTSTR CommandLine)
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
      FATAL("Failed to get exit status (error %lu).", GetLastError());
   }

   CloseHandle(ProcessInformation.hProcess);
   CloseHandle(ProcessInformation.hThread);
   return exit_code;
}

/**
 * Sets up a process to be created after all other opcodes have been processed. This can be used to create processes
 * after the temporary files have all been created and memory has been freed.
 */
BOOL SetScript(LPTSTR app_name, LPTSTR cmd_line)
{
    DEBUG("SetScript");
    if (Script_ApplicationName || Script_CommandLine) {
        FATAL("Script is already set")
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

BOOL SetEnv(LPTSTR Name, LPTSTR Value)
{
   LPTSTR ExpandedValue = ReplaceInstDirPlaceholder(Value);

   DEBUG("SetEnv(%s, %s)", Name, ExpandedValue);

   BOOL Result = FALSE;
   if (!SetEnvironmentVariable(Name, ExpandedValue))
   {
      FATAL("Failed to set environment variable (error %lu).", GetLastError());
      Result = FALSE;
   }
   else
   {
      Result = TRUE;
   }
   LocalFree(ExpandedValue);
   return Result;
}
