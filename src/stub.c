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
#include "unpack.h"
#include "stub.h"

const BYTE Signature[] = { 0x41, 0xb6, 0xba, 0x4e };

BOOL ProcessImage(LPVOID pSeg, DWORD data_len, BOOL compressed);

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

    /* Get the file size */
    LARGE_INTEGER fileSize;
    if (!GetFileSizeEx(hImage, &fileSize)) {
        CloseHandle(hImage);
        return LAST_ERROR("Failed to get executable file size");
    }
    // Check if the file size exceeds the maximum size that can be processed in a 32-bit environment
    if (fileSize.QuadPart > SIZE_MAX) {
        CloseHandle(hImage);
        return FATAL("File size exceeds processable limit");
    }
    size_t image_size = (size_t)fileSize.QuadPart;  // Used to determine the pointer range that can be addressed

    /* Create a file mapping */
    HANDLE hMem = CreateFileMapping(hImage, NULL, PAGE_READONLY, 0, 0, NULL);
    if (hMem == INVALID_HANDLE_VALUE) {
        CloseHandle(hImage);
        return LAST_ERROR("Failed to create file mapping");
    }

    /* Map the image into memory */
    LPVOID lpv = MapViewOfFile(hMem, FILE_MAP_READ, 0, 0, 0);
    if (lpv == NULL) {
        CloseHandle(hMem);
        CloseHandle(hImage);
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

    const char *inst_dir;
    if (IS_EXTRACT_TO_EXE_DIR_ENABLED(flags)) {
        inst_dir = CreateDebugExtractInstDir();
    } else {
        inst_dir = CreateTemporaryInstDir();
    }
    if (inst_dir == NULL) {
        return FATAL("Failed to create installation directory");
    }

    DEBUG("Created installation directory: %s", inst_dir);

    /* Unpacking process */
    if (!ProcessImage(head, tail - head, IS_DATA_COMPRESSED(flags))) {
        exit_code = EXIT_CODE_FAILURE;
    }

    /* Release resources used for image reading */
    BOOL release_failed = FALSE;
    if (!UnmapViewOfFile(lpv)) {
        LAST_ERROR("Failed to unmap view of executable");
        release_failed = TRUE;
    }
    if (!CloseHandle(hMem)) {
        LAST_ERROR("Failed to close file mapping");
        release_failed = TRUE;
    }
    if (!CloseHandle(hImage)) {
        LAST_ERROR("Failed to close executable");
        release_failed = TRUE;
    }
    if (release_failed) {
        exit_code = EXIT_CODE_FAILURE;
    } else {
        /* Launching the script, provided there are no errors in file extraction from the image */
        const char *app_name;
        char *cmd_line;
        if (GetScriptInfo(&app_name, &cmd_line)) {
            DEBUG("*** Starting application script in %s", inst_dir);

            if (IS_CHDIR_BEFORE_SCRIPT_ENABLED(flags)) {
                if (!ChangeDirectoryToScriptDirectory()) {
                    exit_code = FATAL("Failed to change directory to the script location");
                }
            }

            if (exit_code == 0) {
                if (SetEnvironmentVariable("OCRAN_EXECUTABLE", image_path)) {
                    DEBUG("Run application script: %s %s %s", app_name, cmd_line, lpCmdLine);
                    if (!RunScript(lpCmdLine, &exit_code)) {
                        FATAL("Failed to run script");
                    }
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
