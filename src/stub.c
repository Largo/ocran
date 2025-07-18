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
#include "system_utils.h"
#include "inst_dir.h"
#include "script_info.h"
#include "unpack.h"

int main(int argc, char *argv[])
{
    int status = EXIT_CODE_FAILURE;
    UnpackContext *unpack_ctx = NULL;
    OperationModes op_modes = 0;
    const char *extract_dir = NULL;
    char *image_path = NULL;

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
    image_path = GetImagePath();
    if (!image_path) {
        FATAL("Failed to get executable name");
        goto cleanup;
    }

    /* Open and map the image (executable) into memory */
    unpack_ctx = OpenPackFile(image_path);
    if (!unpack_ctx) {
        FATAL("Failed to map the executable file");
        goto cleanup;
    }

    /* Read header of packed data */
    op_modes = GetOperationModes(unpack_ctx);

    /* Enable debug mode when the flag is set */
    if (IsDebugMode(op_modes)) {
        EnableDebugMode();
        DEBUG("Ocran stub running in debug mode");
    }

    /* Create extraction directory */
    extract_dir = CreateInstDir(IsExtractToExeDir(op_modes));
    if (!extract_dir) {
        FATAL("Failed to create extraction directory");
        goto cleanup;
    }

    DEBUG("Created extraction directory: %s", extract_dir);

    /* Unpacking process */
    if (!ProcessImage(unpack_ctx)) {
        FATAL("Failed to unpack image due to invalid or corrupted data");
        goto cleanup;
    }

    // Memory map no longer needed after unpacking; free its resources.
    ClosePackFile(unpack_ctx);

    // Prevent accidental use of the freed map.
    unpack_ctx = NULL;

    /* Launching the script, provided there are no errors in file extraction from the image */
    DEBUG("*** Starting application script in %s", extract_dir);

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
    if (!RunScript(argv, IsChdirBeforeScript(op_modes), &status)) {
        FATAL("Failed to run script");
        goto cleanup;
    }
    /*
       If the script executes successfully, its return code is stored in status.
    */

cleanup:
    /*
       Suppress GUI error dialogs during cleanup to avoid blocking the user.
       Cleanup failures are non-critical and logged as DEBUG only.
    */

    if (image_path) {
        free(image_path);
    }

    if (unpack_ctx) {
        ClosePackFile(unpack_ctx);
        unpack_ctx = NULL;
    }

    FreeScriptInfo();

    /*
       If AUTO_CLEAN_INST_DIR is set, delete the extraction directory.
    */
    if (IsAutoCleanInstDir(op_modes)) {
        DEBUG("Deleting extraction directory: %s", extract_dir);
        if (!DeleteInstDir()) {
            DEBUG("Failed to delete extraction directory");
        }
    }

    FreeInstDir();
    extract_dir = NULL;
    return status;
}
