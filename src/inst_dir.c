#include <windows.h>
#include "error.h"
#include "filesystem_utils.h"
#include "inst_dir.h"

// Static variable to hold the installation directory path.
static const char *InstDir = NULL;

// Creates an installation directory with a unique name in the specified target directory.
const char *CreateInstDirectory(const char *target_dir)
{
    if (InstDir != NULL) {
        APP_ERROR("Installation directory has already been set");
        return NULL;
    }

    const char *inst_dir = CreateUniqueDirectory(target_dir, "ocran");
    if (inst_dir == NULL) {
        APP_ERROR("Failed to create a unique installation directory within the specified target directory");
        return NULL;
    }

    InstDir = inst_dir;
    return inst_dir;
}

// Creates a debug installation directory next to the executable.
const char *CreateDebugExtractInstDir(void)
{
    char *image_dir = GetImageDirectoryPath();
    if (image_dir == NULL) {
        APP_ERROR("Failed to obtain the directory path of the executable file");
        return NULL;
    }

    const char *inst_dir = CreateInstDirectory(image_dir);
    LocalFree(image_dir);
    if (inst_dir == NULL) {
        APP_ERROR("Failed to create installation directory in the executable's directory");
    }

    return inst_dir;
}

// Creates a temporary installation directory in the system's temp directory.
const char *CreateTemporaryInstDir(void)
{
    char *temp_dir = GetTempDirectoryPath();
    if (temp_dir == NULL) {
        APP_ERROR("Failed to obtain the temporary directory path");
        return NULL;
    }

    const char *inst_dir = CreateInstDirectory(temp_dir);
    LocalFree(temp_dir);
    if (inst_dir == NULL) {
        APP_ERROR("Failed to create installation directory in the temporary directory");
    }

    return inst_dir;
}

// Frees the allocated memory for the installation directory path.
void FreeInstDir(void)
{
    LocalFree((void *)InstDir);
    InstDir = NULL;
}

// Returns the path to the installation directory.
const char *GetInstDir()
{
    if (InstDir == NULL || *InstDir == '\0') {
        APP_ERROR("Installation directory is not set or is empty");
        return NULL;
    }

    return InstDir;
}

// Concatenates the installation directory path with a relative path.
char *ExpandInstDirPath(const char *rel_path)
{
    if (InstDir == NULL || *InstDir == '\0') {
        APP_ERROR("Failed to expand path: installation directory (InstDir) is not set");
        return NULL;
    }

    if (rel_path == NULL || *rel_path == '\0') {
        APP_ERROR("Failed to expand path: relative path argument is null or empty");
        return NULL;
    }

    if (!IsPathFreeOfDotElements(rel_path)) {
        APP_ERROR("Failed to expand path: relative path '%s' contains '.' or '..' elements", rel_path);
        return NULL;
    }

    return JoinPath(InstDir, rel_path);
}

// Deletes the installation directory and all its contents.
BOOL DeleteInstDirRecursively(void)
{
    if (InstDir == NULL || *InstDir == '\0') {
        APP_ERROR("InstDir is null or empty");
        return FALSE;
    }

    return DeleteRecursively(InstDir);
}

// Creates a marker file indicating the directory is to be deleted.
void MarkInstDirForDeletion(void)
{
    if (InstDir == NULL || *InstDir == '\0') {
        APP_ERROR("InstDir is null or empty");
        return;
    }

    size_t inst_dir_len = strlen(InstDir);
    size_t suffix_len = strlen(DELETION_MAKER_SUFFIX);
    size_t len = inst_dir_len + suffix_len;
    char *marker = LocalAlloc(LPTR, len + 1);
    if (marker == NULL) {
        LAST_ERROR("Failed to allocate memory for deletion marker path");
        return;
    }
    memcpy(marker, InstDir, inst_dir_len);
    memcpy(marker + inst_dir_len, DELETION_MAKER_SUFFIX, suffix_len);
    marker[len] = '\0';

    HANDLE h = CreateFile(marker, 0, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        LAST_ERROR("Failed to mark for deletion");
        return;
    }

    APP_ERROR("Deletion marker path is %s", marker);
    CloseHandle(h);
    LocalFree(marker);
}

// Replaces placeholders in a string with the installation directory path.
char *ReplaceInstDirPlaceholder(const char *str)
{
    if (InstDir == NULL || *InstDir == '\0') {
        APP_ERROR("InstDir is null or empty");
        return FALSE;
    }

    int InstDirLen = strlen(InstDir);
    const char *p;
    int c = 0;

    for (p = str; *p; p++) { if (*p == PLACEHOLDER) c++; }
    SIZE_T out_len = strlen(str) - c + InstDirLen * c + 1;
    char *out = (char *)LocalAlloc(LPTR, out_len);

    if (out == NULL) {
        LAST_ERROR("LocalAlloc failed");
        return NULL;
    }

    char *out_p = out;

    for (p = str; *p; p++) {
        if (*p == PLACEHOLDER) {
            memcpy(out_p, InstDir, InstDirLen);
            out_p += InstDirLen;
        } else {
            *out_p = *p;
            out_p++;
        }
    }
    *out_p = '\0';

    return out;
}

// Changes the working directory to the directory where the script is located.
BOOL ChangeDirectoryToScriptDirectory(void)
{
    char *script_dir = ExpandInstDirPath("src");
    if (script_dir == NULL) {
        APP_ERROR("Failed to build path for CWD");
        return FALSE;
    }

    DEBUG("Changing CWD to unpacked directory %s", script_dir);

    BOOL changed = SetCurrentDirectory(script_dir);
    if (!changed) {
        LAST_ERROR("Failed to change CWD");
    }
    LocalFree(script_dir);

    return changed;
}

BOOL CreateDirectoryUnderInstDir(const char *rel_path)
{
    if (rel_path == NULL) {
        return FALSE;
    }

    if (*rel_path == '\0') {
        return TRUE;
    }

    char *dir = ExpandInstDirPath(rel_path);
    if (dir == NULL) {
        return FALSE;
    }

    BOOL result = CreateDirectoriesRecursively(dir);
    if (!result) {
        APP_ERROR("Failed to create directory under installation directory (InstDir): '%s'", dir);
    }

    LocalFree(dir);
    return result;
}

static BOOL export_file(const char *path, const void *buf, size_t len)
{
    BOOL   result  = FALSE;
    HANDLE h       = INVALID_HANDLE_VALUE;
    DWORD  written = 0;

    if (len > MAXDWORD) {
        DEBUG("export_file: Write length %zu exceeds maximum DWORD", len);
        goto cleanup;
    }

    h = CreateFile(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        DEBUG("export_file: CreateFile failed, err=%u", GetLastError());
        goto cleanup;
    }

    if (!WriteFile(h, buf, (DWORD)len, &written, NULL)) {
        DEBUG("export_file: WriteFile failed, err=%u", GetLastError());
        goto cleanup;
    }

    if (written != (DWORD)len) {
        DEBUG("export_file: Write size mismatch, expected %zu, wrote %u", len, written);
        goto cleanup;
    }

    result = TRUE;

cleanup:
    if (h != INVALID_HANDLE_VALUE) {
        CloseHandle(h);
    }
    return result;
}

BOOL ExportFileToInstDir(const char *rel_path, const void *buf, size_t len)
{
    BOOL  result = FALSE;
    char *path   = NULL;

    if (rel_path == NULL || *rel_path == '\0') {
        APP_ERROR("Relative path is null or empty");
        goto cleanup;
    }

    DEBUG("ExportFileToInstDir: rel_path=\"%s\", len=%zu", rel_path, len);

    if (len > 0 && buf == NULL) {
        APP_ERROR("Buffer pointer is NULL for non-zero length");
        goto cleanup;
    }

    path = ExpandInstDirPath(rel_path);
    if (!path) {
        goto cleanup;
    }

    if (!CreateParentDirectories(path)) {
        APP_ERROR("Failed to create parent directory for %s", path);
        goto cleanup;
    }

    if (!export_file(path, buf, len)) {
        APP_ERROR("Failed to export file: %s", path);
        goto cleanup;
    }

    result = TRUE;

cleanup:
    if (path) {
        LocalFree(path);
    }
    return result;
}
