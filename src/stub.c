/*
  Single Executable Bundle Stub
  This stub reads itself for embedded instructions to create directory
  and files in a temporary directory, launching a program.
*/

#include <string.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include "error.h"
#include "system_utils.h"
#include "inst_dir.h"
#include "unpack.h"

#ifdef _WIN32
#define LAUNCHER_REL_PATH "bin\\ocran_launcher.rb"
#else
#define LAUNCHER_REL_PATH "bin/ocran_launcher.rb"
#endif

int main(int argc, char *argv[])
{
    int status = EXIT_CODE_FAILURE;
    UnpackContext *unpack_ctx = NULL;
    OperationModes op_modes = 0;
    const char *extract_dir = NULL;
    char *image_path = NULL;
    char *launcher_path = NULL;
    char **launch_argv = NULL;

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

    /* Enable debug mode when the flag is set or OCRAN_DEBUG env var is set */
    if (IsDebugMode(op_modes) || getenv("OCRAN_DEBUG")) {
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

    /* Unpack bootstrap section (Ruby interpreter, launcher, shared libs) */
    if (!ProcessImage(unpack_ctx)) {
        FATAL("Failed to unpack image due to invalid or corrupted data");
        goto cleanup;
    }

    /* Retrieve main data location before closing the memory map */
    size_t main_data_offset = GetMainDataOffset(unpack_ctx);
    size_t main_data_size = GetMainDataSize(unpack_ctx);

    // Memory map no longer needed after unpacking; free its resources.
    ClosePackFile(unpack_ctx);

    // Prevent accidental use of the freed map.
    unpack_ctx = NULL;

    /* Set environment variables for the Ruby launcher */
    DEBUG("Set OCRAN_EXECUTABLE to %s", image_path);
    if (!SetEnvVar("OCRAN_EXECUTABLE", image_path)) {
        FATAL("Failed to set OCRAN_EXECUTABLE");
        goto cleanup;
    }

    DEBUG("Set OCRAN_INST_DIR to %s", extract_dir);
    if (!SetEnvVar("OCRAN_INST_DIR", extract_dir)) {
        FATAL("Failed to set OCRAN_INST_DIR");
        goto cleanup;
    }

    char modes_str[16];
    snprintf(modes_str, sizeof(modes_str), "%u", (unsigned)op_modes);
    if (!SetEnvVar("OCRAN_OPERATION_MODES", modes_str)) {
        FATAL("Failed to set OCRAN_OPERATION_MODES");
        goto cleanup;
    }

    /* Pass main data location to the Ruby launcher */
    char offset_str[32], size_str[32];
    snprintf(offset_str, sizeof(offset_str), "%zu", main_data_offset);
    snprintf(size_str, sizeof(size_str), "%zu", main_data_size);

    if (!SetEnvVar("OCRAN_DATA_OFFSET", offset_str)) {
        FATAL("Failed to set OCRAN_DATA_OFFSET");
        goto cleanup;
    }

    if (!SetEnvVar("OCRAN_DATA_SIZE", size_str)) {
        FATAL("Failed to set OCRAN_DATA_SIZE");
        goto cleanup;
    }

    /* Launch the Ruby launcher */
    const char *ruby_path = getenv("OCRAN_RUBY_PATH");
    if (!ruby_path || !*ruby_path) {
        FATAL("OCRAN_RUBY_PATH not set (bootstrap section incomplete)");
        goto cleanup;
    }

    launcher_path = ExpandInstDirPath(LAUNCHER_REL_PATH);
    if (!launcher_path) {
        FATAL("Failed to expand launcher path");
        goto cleanup;
    }

    /* Count user arguments (skip argv[0] which is the exe name) */
    size_t user_argc = 0;
    if (argv) {
        for (char **p = argv + 1; p && *p; p++) user_argc++;
    }

    /* Build argv: ruby_path, launcher_path, [user_args...], NULL */
    size_t total = 2 + user_argc + 1;
    launch_argv = calloc(total, sizeof(char *));
    if (!launch_argv) {
        FATAL("Memory allocation failed for launcher argv");
        goto cleanup;
    }

    launch_argv[0] = (char *)ruby_path;
    launch_argv[1] = launcher_path;
    for (size_t i = 0; i < user_argc; i++) {
        launch_argv[2 + i] = argv[1 + i];
    }
    launch_argv[2 + user_argc] = NULL;

    DEBUG("*** Launching Ruby launcher: %s %s", ruby_path, launcher_path);

    if (!CreateAndWaitForProcess(ruby_path, launch_argv, &status)) {
        FATAL("Failed to launch Ruby launcher");
        goto cleanup;
    }

cleanup:
    /*
       Suppress GUI error dialogs during cleanup to avoid blocking the user.
       Cleanup failures are non-critical and logged as DEBUG only.
    */

    if (launch_argv) {
        free(launch_argv);
    }

    if (launcher_path) {
        free(launcher_path);
    }

    if (image_path) {
        free(image_path);
    }

    if (unpack_ctx) {
        ClosePackFile(unpack_ctx);
        unpack_ctx = NULL;
    }

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
