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

const void *FindSignature(const void *buffer, size_t size)
{
    if (size < sizeof(Signature)) {
        FATAL("Buffer too small to contain signature");
        return NULL;
    }

    // Currently, the signature is being searched for at the end of the file.
    const void *sig = (const char *)buffer + size - sizeof(Signature);

    if (memcmp(sig, Signature, sizeof(Signature)) != 0) {
        FATAL("Signature not found in executable");
        return NULL;
    }

    return sig;
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
    DWORD exit_code = EXIT_CODE_SUCCESS;
    MappedFile mapped_file = NULL;
    OperationModes flags = 0;

    /*
       Set up the console control handler to ignore all control signals.
       This is crucial because it allows the parent process to continue running
       without interruption during initial file operations and other setup tasks.
       Control signals are managed independently by the child process (Ruby),
       which has its own signal handling mechanisms. This design ensures that
       the parent process can perform critical cleanup and other tasks without
       being prematurely terminated by such signals.
    */
    if (!SetConsoleCtrlHandler(&ConsoleHandleRoutine, TRUE)) {
        LAST_ERROR("Failed to set control handler");
        exit_code = FATAL("Failed to initialize system controls");
        goto cleanup;
    }

    /* Find name of image */
    char *image_path = GetImagePath();
    if (image_path == NULL) {
        exit_code = FATAL("Failed to get executable name");
        goto cleanup;
    }

    /* Open and map the image (executable) into memory */
    unsigned long long file_size = 0;
    const void *base = NULL;
    mapped_file = OpenAndMapFile(image_path, &file_size, &base);
    if (mapped_file == NULL) {
        exit_code = FATAL("Failed to open or map the executable file");
        goto cleanup;
    }

    // Check if the file size exceeds the maximum size that can be processed in a 32-bit environment
    if (file_size > SIZE_MAX) {
        exit_code = FATAL("File size exceeds processable limit");
        goto cleanup;
    }
    size_t image_size = (size_t)file_size;  // Used to determine the pointer range that can be addressed

    /* Process the image by checking the signature and locating the first opcode */
    const void *sig = FindSignature(base, image_size);
    if (sig == NULL) {
        exit_code = FATAL("Bad signature in executable");
        goto cleanup;
    }

    const void *tail = (const char *)sig - sizeof(DWORD);
    size_t offset = *(const DWORD*)(tail);
    const void *head = (const char *)base + offset;

    /* Read header of packed data */
    // Read the operation mode flag from the packed data header
    flags = (OperationModes)*(BYTE *)head;
    // Move to the next byte in the data stream
    head = (BYTE *)head + 1;

    /* Initialize Debug Mode if Enabled */
    if (IS_DEBUG_MODE_ENABLED(flags)) {
        InitializeDebugMode();
        DEBUG("Ocran stub running in debug mode");
    }

    /* Create installation directory */
    const char *inst_dir = NULL;
    if (IS_EXTRACT_TO_EXE_DIR_ENABLED(flags)) {
        inst_dir = CreateDebugExtractInstDir();
    } else {
        inst_dir = CreateTemporaryInstDir();
    }
    if (inst_dir == NULL) {
        exit_code = FATAL("Failed to create installation directory");
        goto cleanup;
    }

    DEBUG("Created installation directory: %s", inst_dir);

    /* Unpacking process */
    if (!ProcessImage(head, tail - head, IS_DATA_COMPRESSED(flags))) {
        exit_code = FATAL("Failed to unpack image due to invalid or corrupted data");
        goto cleanup;
    }

    /*
       After successful unpacking, mapped_file is no longer needed. Freeing up
       system resources as the memory map is only used for file extraction and
       is now redundant.
    */
    BOOL release_ok = FreeMappedFile(mapped_file);
    /*
       Set the pointer to NULL after calling FreeMappedFile to avoid reuse.
       FreeMappedFile always releases the resource, regardless of the success
       of the underlying release operations.
    */
    mapped_file = NULL;
    if (!release_ok) {
        exit_code = FATAL("Failed to release mapped file resources");
        goto cleanup;
    }

    /* Launching the script, provided there are no errors in file extraction from the image */
    const char *app_name;
    char *cmd_line;
    if (!GetScriptInfo(&app_name, &cmd_line)) {
        exit_code = FATAL("Failed to retrieve script information");
        goto cleanup;
    }

    DEBUG("*** Starting application script in %s", inst_dir);

    if (IS_CHDIR_BEFORE_SCRIPT_ENABLED(flags)) {
        DEBUG("Change directory to the script location before running the script");
        if (!ChangeDirectoryToScriptDirectory()) {
            exit_code = FATAL("Failed to change directory to the script location");
            goto cleanup;
        }
    }
    DEBUG("Set the 'OCRAN_EXECUTABLE' environment variable to %s", image_path);
    if (!SetEnvironmentVariable("OCRAN_EXECUTABLE", image_path)) {
        LAST_ERROR("Failed to set the 'OCRAN_EXECUTABLE' environment variable");
        exit_code = FATAL("The script cannot be launched due to a configuration error");
        goto cleanup;
    }
    DEBUG("Run application script: %s %s %s", app_name, cmd_line, lpCmdLine);
    if (!RunScript(lpCmdLine, &exit_code)) {
        exit_code = FATAL("Failed to run script");
        goto cleanup;
    }

cleanup:

    if (mapped_file) {
        FreeMappedFile(mapped_file);
        mapped_file = NULL;
    }

    FreeScriptInfo();

    /* If necessary, recursively delete the installation directory */
    /*
       Retrieve the installation directory path using GetInstDir() to ensure we
       only attempt to delete directories that were properly initialized and are
       still relevant. This prevents any deletion operations on non-existent or
       previously cleaned-up directories.
    */
    const char *current_inst_dir = GetInstDir();
    if (current_inst_dir != NULL && IS_AUTO_CLEAN_INST_DIR_ENABLED(flags)) {
        DEBUG("Deleting temporary installation directory: %s", current_inst_dir);

        if (IS_CHDIR_BEFORE_SCRIPT_ENABLED(flags)) {
            if (!ChangeDirectoryToSafeDirectory()) {
                FATAL("Failed to change the current directory to a safe location; "
                      "proceeding with deletion process");
                /*
                   The attempt to change to a safe directory failed. While this failure does not
                   halt the process, it may prevent the complete deletion of the installation
                   directory. The operation will proceed under the assumption that partial
                   cleanup may still be preferable or required.
                */
            }
        }
        if (!DeleteInstDirRecursively()) {
            FATAL("Failed to delete installation directory");
            MarkInstDirForDeletion();
        }
    }

    FreeInstDir();
    return exit_code;
}
