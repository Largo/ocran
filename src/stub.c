/*
  Single Executable Bundle Stub
  This stub reads itself for embedded instructions to create directory
  and files in a temporary directory, launching a program.
*/

#include <windows.h>
#include <string.h>
#include <stdio.h>
#include "error.h"
#include "filesystem_utils.h"
#include "inst_dir.h"
#include "script_info.h"
#include "stub.h"
#include "unpack.h"

const BYTE Signature[] = { 0x41, 0xb6, 0xba, 0x4e };

BOOL ProcessImage(LPVOID pSeg, DWORD data_len, BOOL compressed);
DWORD CreateAndWaitForProcess(const char *app_name, char *cmd_line);

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

BOOL ChangeDirectoryToSafeDirectory(void)
{
    char *working_dir = GetTempDirectoryPath();
    BOOL changed = working_dir && SetCurrentDirectory(working_dir);
    LocalFree(working_dir);

    if (changed) return TRUE;

    DEBUG("Failed to change to temporary directory. Trying executable's directory");
    working_dir = GetImageDirectoryPath();
    changed = working_dir && SetCurrentDirectory(working_dir);
    LocalFree(working_dir);

    if (!changed) {
        DEBUG("Failed to change to executable's directory");
    }

    return changed;
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

int CALLBACK WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
    DWORD exit_code = 0;

    /* Find name of image */
    char *image_path = GetImagePath();
    if (image_path == NULL) {
        return LAST_ERROR("Failed to get executable name");
    }

   SetConsoleCtrlHandler(&ConsoleHandleRoutine, TRUE);

    /* Open the image (executable) */
    HANDLE hImage = CreateFile(image_path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (hImage == INVALID_HANDLE_VALUE) {
        return LAST_ERROR("Failed to open executable file");
    }

    /* Create a file mapping */
    DWORD image_size = GetFileSize(hImage, NULL);
    HANDLE hMem = CreateFileMapping(hImage, NULL, PAGE_READONLY, 0, image_size, NULL);
    if (hMem == INVALID_HANDLE_VALUE) {
        return LAST_ERROR("Failed to create file mapping");
    }

    /* Map the image into memory */
    LPVOID lpv = MapViewOfFile(hMem, FILE_MAP_READ, 0, 0, 0);
    if (lpv == NULL) {
        return LAST_ERROR("Failed to map view of executable into memory");
    }

    /* Process the image by checking the signature and locating the first opcode */
    void *sig = lpv + image_size - sizeof(Signature);

    if (memcmp(sig, Signature, sizeof(Signature)) != 0) {
        return FATAL("Bad signature in executable");
    }

    void *tail = sig - sizeof(DWORD);
    DWORD OpcodeOffset = *(DWORD*)(tail);
    void *head = lpv + OpcodeOffset;

    /* Read header of packed data */
    OperationModes flags = (OperationModes)*(BYTE *)head; head++;

    DebugModeEnabled = IS_DEBUG_MODE_ENABLED(flags);

    if (DebugModeEnabled) {
        DEBUG("Ocran stub running in debug mode");
    }

    BOOL created;

    if (IS_EXTRACT_TO_EXE_DIR_ENABLED(flags)) {
        created = InitializeDebugExtractInstDir();
    } else {
        created = InitializeTemporaryInstDir();
    }

    if (!created) {
        return FATAL("Failed to create installation directory");
    }

    const char *inst_dir = GetInstDir();

    if (inst_dir == NULL) {
        return FATAL("Failed to get installation directory");
    }

    DEBUG("Created installation directory: %s", inst_dir);

    /* Unpacking process */
    if (!ProcessImage(head, tail - head, IS_DATA_COMPRESSED(flags))) {
        exit_code = EXIT_CODE_FAILURE;
    }

    /* Release resources used for image reading */
    if (!UnmapViewOfFile(lpv)) {
        exit_code = LAST_ERROR("Failed to unmap view of executable");
    } else if (!CloseHandle(hMem)) {
        exit_code = LAST_ERROR("Failed to close file mapping");
    } else if (!CloseHandle(hImage)) {
        exit_code = LAST_ERROR("Failed to close executable");
    } else {
        /* Launching the script, provided there are no errors in file extraction from the image */
        const char *app_name;
        char *cmd_line;
        if (GetScriptInfo(&app_name, &cmd_line)) {
            DEBUG("*** Starting app in %s", inst_dir);

            if (IS_CHDIR_BEFORE_SCRIPT_ENABLED(flags)) {
                char *script_dir = ExpandInstDirPath("src");
                if (script_dir) {
                    DEBUG("Changing CWD to unpacked directory %s", script_dir);

                    if (!SetCurrentDirectory(script_dir)) {
                        exit_code = LAST_ERROR("Failed to change CWD");
                    }
                    LocalFree(script_dir);
                } else {
                    exit_code = FATAL("Failed to build path for CWD");
                }
            }

            if (exit_code == 0) {
                if (SetEnvironmentVariable("OCRAN_EXECUTABLE", image_path)) {
                    exit_code = CreateAndWaitForProcess(app_name, cmd_line);
                } else {
                    exit_code = LAST_ERROR("Failed to set the 'OCRAN_EXECUTABLE' environment variable");
                }
            }
        }
    }

    FreeScriptInfo();

    /* If necessary, recursively delete the installation directory */
    if (IS_AUTO_CLEAN_INST_DIR_ENABLED(flags)) {
        DEBUG("Deleting temporary installation directory %s", inst_dir);

        if (IS_CHDIR_BEFORE_SCRIPT_ENABLED(flags)) {
            if (!ChangeDirectoryToSafeDirectory()) {
                FATAL("Failed to change the current directory to a safe location");
            }
        }

        if (!DeleteInstDirRecursively()) {
            MarkInstDirForDeletion();
        }
    }

    inst_dir = NULL;
    FreeInstDir();
    return exit_code;
}

BOOL ProcessImage(LPVOID pSeg, DWORD data_len, BOOL compressed)
{
    BYTE last_opcode;

    if (compressed) {
#if WITH_LZMA
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
BOOL MakeFile(const char *file_name, size_t file_size, const void *data)
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

        if (!WriteFile(h, data, (DWORD)file_size, &BytesWritten, NULL)) {
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
BOOL MakeDirectory(const char *dir_name)
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

DWORD CreateAndWaitForProcess(const char *app_name, char *cmd_line)
{
    DEBUG("Create process (%s, %s)", app_name, cmd_line);

    DWORD exit_code = 0;
    PROCESS_INFORMATION p_info;
    ZeroMemory(&p_info, sizeof(p_info));
    STARTUPINFO s_info;
    ZeroMemory(&s_info, sizeof(s_info));
    s_info.cb = sizeof(s_info);
    if (CreateProcess(app_name, cmd_line, NULL, NULL, TRUE, 0, NULL, NULL, &s_info, &p_info)) {
        if (WaitForSingleObject(p_info.hProcess, INFINITE) == WAIT_FAILED) {
            exit_code = LAST_ERROR("Failed to wait script process");
        } else {
            if (!GetExitCodeProcess(p_info.hProcess, &exit_code)) {
                exit_code = LAST_ERROR("Failed to get exit status");
            }
        }
        CloseHandle(p_info.hProcess);
        CloseHandle(p_info.hThread);
    } else {
        exit_code = LAST_ERROR("Failed to create process");
    }

    return exit_code;
}

/**
 * Sets up a process to be created after all other opcodes have been processed. This can be used to create processes
 * after the temporary files have all been created and memory has been freed.
 */
BOOL SetScript(const char *args, size_t args_size)
{
    DEBUG("SetScript");

    char *MyArgs = SkipArg(GetCommandLine());

    return InitializeScriptInfo(args, args_size, MyArgs);
}

BOOL SetEnv(const char *name, const char *value)
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
