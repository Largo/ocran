/*
  Single Executable Bundle Stub
  This stub reads itself for embedded instructions to create directory
  and files in a temporary directory, launching a program.
*/

#include <windows.h>
#include <string.h>
#include <stdio.h>
#include <stdbool.h>
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
        DEBUG("Buffer too small to contain signature");
        return NULL;
    }

    // Currently, the signature is being searched for at the end of the file.
    const void *sig = (const char *)buffer + size - sizeof(Signature);

    if (memcmp(sig, Signature, sizeof(Signature)) != 0) {
        DEBUG("Signature not found in executable");
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


int main(int argc, char *argv[])
{
    int exit_code = EXIT_CODE_FAILURE;
    MemoryMap *map = NULL;
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
        APP_ERROR("Failed to set control handler (%lu)", GetLastError());
        FATAL("Failed to initialize system controls");
        goto cleanup;
    }

    /* Find name of image */
    char *image_path = GetImagePath();
    if (image_path == NULL) {
        FATAL("Failed to get executable name");
        goto cleanup;
    }

    /* Open and map the image (executable) into memory */
    map = CreateMemoryMap(image_path);
    if (!map) {
        FATAL("Failed to map the executable file");
        goto cleanup;
    }

    void * base = GetMemoryMapBase(map);
    size_t image_size = GetMemoryMapSize(map);

    /* Process the image by checking the signature and locating the first opcode */
    const void *sig = FindSignature(base, image_size);
    if (sig == NULL) {
        FATAL("Bad signature in executable");
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

    /* Enable debug mode when the flag is set */
    if (IS_DEBUG_MODE(flags)) {
        EnableDebugMode();
        DEBUG("Ocran stub running in debug mode");
    }

    /* Create installation directory */
    const char *inst_dir = NULL;
    if (IS_EXTRACT_TO_EXE_DIR(flags)) {
        inst_dir = CreateDebugExtractInstDir();
    } else {
        inst_dir = CreateTemporaryInstDir();
    }
    if (inst_dir == NULL) {
        FATAL("Failed to create installation directory");
        goto cleanup;
    }

    DEBUG("Created installation directory: %s", inst_dir);

    /* Unpacking process */
    if (!ProcessImage(head, tail - head, IS_DATA_COMPRESSED(flags))) {
        FATAL("Failed to unpack image due to invalid or corrupted data");
        goto cleanup;
    }

    // Memory map no longer needed after unpacking; free its resources.
    DestroyMemoryMap(map);

    // Prevent accidental use of the freed map.
    map = NULL;

    /* Launching the script, provided there are no errors in file extraction from the image */
    DEBUG("*** Starting application script in %s", inst_dir);

    if (IS_CHDIR_BEFORE_SCRIPT(flags)) {
        DEBUG("Change directory to the script location before running the script");
        if (!ChangeDirectoryToScriptDirectory()) {
            FATAL("Failed to change directory to the script location");
            goto cleanup;
        }
    }
    DEBUG("Set the 'OCRAN_EXECUTABLE' environment variable to %s", image_path);
    if (!SetEnvironmentVariable("OCRAN_EXECUTABLE", image_path)) {
        APP_ERROR("Failed to set the 'OCRAN_EXECUTABLE' environment variable (%lu)", GetLastError());
        FATAL("The script cannot be launched due to a configuration error");
        goto cleanup;
    }

    /*
       RunScript uses the current value of exit_code as its initial value
       and then overwrites it with the external script’s return code.
       Therefore, we must set the success code here.
    */
    exit_code = EXIT_CODE_SUCCESS;

    DEBUG("Run application script");
    if (!RunScript(argc, argv, &exit_code)) {
        exit_code = EXIT_CODE_FAILURE;
        FATAL("Failed to run script");
        goto cleanup;
    }
    /*
       If the script executes successfully, its return code is stored in exit_code.
    */

cleanup:
    /*
       During cleanup, GUI error dialogs are suppressed to avoid blocking the user.
       Cleanup failures are non-critical resource release issues;
       they are logged with DEBUG output only, preventing unnecessary user interaction
       and reducing risk of exposing internal details.
    */

    if (map) {
        DestroyMemoryMap(map);
        map = NULL;
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
    if (current_inst_dir != NULL && IS_AUTO_CLEAN_INST_DIR(flags)) {
        DEBUG("Deleting temporary installation directory: %s", current_inst_dir);

        if (IS_CHDIR_BEFORE_SCRIPT(flags)) {
            if (!ChangeDirectoryToSafeDirectory()) {
                DEBUG("Failed to change the current directory to a safe location; "
                      "proceeding with deletion process");
                /*
                   The attempt to change to a safe directory failed. While this failure does not
                   halt the process, it may prevent the complete deletion of the installation
                   directory. The operation will proceed under the assumption that partial
                   cleanup may still be preferable or required.
                */
            }
        }
        if (!DeleteInstDir()) {
            DEBUG("Failed to delete installation directory");
        }
    }

    FreeInstDir();
    return exit_code;
}
