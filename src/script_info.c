#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "error.h"
#include "system_utils.h"
#include "inst_dir.h"
#include "script_info.h"

/* Raw script info data (double-null-terminated) */
static char *RawInfo = NULL;
static size_t RawInfoSize = 0;

/* First entry (application name / Ruby executable relative path) */
static char *AppName = NULL;

bool IsScriptInfoSet(void)
{
    return RawInfo != NULL;
}

bool SetScriptInfo(const char *info, size_t info_size)
{
    if (RawInfo != NULL) {
        APP_ERROR("Script info is already set");
        return false;
    }

    if (!info) {
        APP_ERROR("info is NULL");
        return false;
    }

    if (info_size < 2
        || info[info_size - 1] != '\0'
        || info[info_size - 2] != '\0') {
        APP_ERROR("Script info not double-NULL terminated");
        return false;
    }

    const char *argv0 = info;
    if (*argv0 == '\0') {
        APP_ERROR("Application name is empty");
        return false;
    }

    if (!IsCleanRelativePath(argv0)) {
        APP_ERROR("Application name contains prohibited relative path elements");
        return false;
    }

    const char *argv1 = argv0 + strlen(argv0) + 1;
    if (*argv1 == '\0') {
        APP_ERROR("Script name is empty");
        return false;
    }

    if (!IsCleanRelativePath(argv1)) {
        APP_ERROR("Script name contains prohibited relative path elements");
        return false;
    }

    /* Store raw data for file export */
    RawInfo = malloc(info_size);
    if (!RawInfo) {
        APP_ERROR("Memory allocation failed for raw script info");
        return false;
    }
    memcpy(RawInfo, info, info_size);
    RawInfoSize = info_size;

    /* Store application name for launcher */
    size_t app_len = strlen(argv0);
    AppName = malloc(app_len + 1);
    if (!AppName) {
        APP_ERROR("Memory allocation failed for app name");
        free(RawInfo);
        RawInfo = NULL;
        return false;
    }
    memcpy(AppName, argv0, app_len + 1);

    return true;
}

void FreeScriptInfo(void)
{
    if (RawInfo) {
        free(RawInfo);
        RawInfo = NULL;
        RawInfoSize = 0;
    }
    if (AppName) {
        free(AppName);
        AppName = NULL;
    }
}

bool WriteScriptInfoFile(void)
{
    if (!RawInfo) {
        APP_ERROR("No script info to write");
        return false;
    }

    char *path = ExpandInstDirPath("ocran_script.info");
    if (!path) {
        return false;
    }

    DEBUG("Writing script info to %s (%zu bytes)", path, RawInfoSize);
    bool result = ExportFile(path, RawInfo, RawInfoSize);
    if (!result) {
        APP_ERROR("Failed to write script info file: %s", path);
    }

    free(path);
    return result;
}

#ifdef _WIN32
#define LAUNCHER_REL_PATH "bin\\ocran_launcher.rb"
#else
#define LAUNCHER_REL_PATH "bin/ocran_launcher.rb"
#endif

bool LaunchLauncher(char *argv[], int *exit_code)
{
    if (!AppName) {
        APP_ERROR("No application name set");
        return false;
    }

    bool result = false;
    char *app_path = NULL;
    char *launcher_path = NULL;
    char **launch_argv = NULL;

    /* Expand the Ruby executable path */
    app_path = ExpandInstDirPath(AppName);
    if (!app_path) {
        APP_ERROR("Failed to expand application path");
        goto cleanup;
    }

    /* Expand the launcher script path */
    launcher_path = ExpandInstDirPath(LAUNCHER_REL_PATH);
    if (!launcher_path) {
        APP_ERROR("Failed to expand launcher path");
        goto cleanup;
    }

    /* Count user arguments (skip argv[0] which is the exe name) */
    size_t user_argc = 0;
    if (argv) {
        for (char **p = argv + 1; p && *p; p++) user_argc++;
    }

    /* Build argv: app_path, launcher_path, [user_args...], NULL */
    size_t total = 2 + user_argc + 1;
    launch_argv = calloc(total, sizeof(char *));
    if (!launch_argv) {
        APP_ERROR("Memory allocation failed for launcher argv");
        goto cleanup;
    }

    launch_argv[0] = app_path;
    launch_argv[1] = launcher_path;
    for (size_t i = 0; i < user_argc; i++) {
        launch_argv[2 + i] = argv[1 + i];
    }
    launch_argv[2 + user_argc] = NULL;

    DEBUG("Launching: %s %s", app_path, launcher_path);

    result = CreateAndWaitForProcess(app_path, launch_argv, exit_code);

cleanup:
    if (launch_argv) free(launch_argv);
    if (app_path) free(app_path);
    if (launcher_path) free(launcher_path);
    return result;
}
