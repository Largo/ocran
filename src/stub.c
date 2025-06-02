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

int main(int argc, char *argv[])
{
    int status = EXIT_CODE_FAILURE;
    MemoryMap *map = NULL;
    OperationModes flags = 0;
    const char *extract_dir = NULL;

    /*
       Initialize signal and control handling so the parent process remains
       active during startup and cleanup. This setup prevents interruption
       of critical tasks (such as file extraction) by control events.
       Child processes (e.g., Ruby) handle their own signals independently,
       ensuring the parent can finalize cleanup without premature termination.
    */
    if (!InitializeSignalHandling()) {
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

    /* Create extraction directory */
    if (IS_EXTRACT_TO_EXE_DIR(flags)) {
        extract_dir = CreateDebugExtractInstDir();
    } else {
        extract_dir = CreateTemporaryInstDir();
    }
    if (!extract_dir) {
        FATAL("Failed to create extraction directory");
        goto cleanup;
    }

    DEBUG("Created extraction directory: %s", extract_dir);

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
    DEBUG("*** Starting application script in %s", extract_dir);

    if (IS_CHDIR_BEFORE_SCRIPT(flags)) {
        DEBUG("Change directory to the script location before running the script");
        if (!ChangeDirectoryToScriptDirectory()) {
            FATAL("Failed to change directory to the script location");
            goto cleanup;
        }
    }
    DEBUG("Set the 'OCRAN_EXECUTABLE' environment variable to %s", image_path);
    if (!SetEnvVar("OCRAN_EXECUTABLE", image_path)) {
        FATAL("The script cannot be launched due to a configuration error");
        goto cleanup;
    }

    /*
       RunScript uses the current value of status as its initial value
       and then overwrites it with the external script’s return code.
    */
    DEBUG("Run application script");
    if (!RunScript(argc, argv, &status)) {
        FATAL("Failed to run script");
        goto cleanup;
    }
    /*
       If the script executes successfully, its return code is stored in status.
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

    /* 
       Move to a safe directory if requested; on failure, log and continue.
    */
    if (IS_CHDIR_BEFORE_SCRIPT(flags)) {
        if (!ChangeDirectoryToSafeDirectory()) {
            DEBUG("Failed to change to a safe working directory. "
                  "Proceeding with deletion.");
            /*
               Safe‐directory change failed. Continue anyway—partial cleanup
               may still be preferable.
            */
        }
    }
    /*
       If auto-cleanup is enabled, delete the extraction directory.
    */
    if (IS_AUTO_CLEAN_INST_DIR(flags)) {
        DEBUG("Deleting extraction directory: %s", extract_dir);
        if (!DeleteInstDir()) {
            DEBUG("Failed to delete extraction directory");
        }
    }

    FreeInstDir();
    extract_dir = NULL;
    return status;
}
