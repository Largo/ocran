#include <stdlib.h>
#include <string.h>
#include "error.h"
#include "system_utils.h"
#include "inst_dir.h"

// Static variable to hold the installation directory path.
static char *InstDir = NULL;

/**
 * @brief Checks whether the installation directory is configured.
 *
 * @return true if InstDir is non-NULL and not empty; false otherwise.
 */
static inline bool IsInstDirSet(void)
{
    return InstDir != NULL && InstDir[0] != '\0';
}

// Creates an installation directory with a unique name in the specified target directory.
static char *create_uniq_dir(const char *target_dir)
{
    char *base_path = JoinPath(target_dir, "ocran" "XXXXXX");
    if (!base_path) {
        APP_ERROR("Failed to construct a base path");
        return NULL;
    }
    return CreateUniqueDirectory(base_path);
}

// Creates a debug installation directory next to the executable.
static char *create_debug_extract_inst_dir(void)
{
    char *image_path = GetImagePath();
    if (!image_path) {
        APP_ERROR("Failed to get executable name");
        return NULL;
    }

    char *image_dir = GetParentPath(image_path);
    free(image_path);
    if (!image_dir) {
        APP_ERROR("Failed to obtain the directory path of the executable file");
        return NULL;
    }

    char *inst_dir = create_uniq_dir(image_dir);
    
    if (!inst_dir) {
        APP_ERROR("Failed to create installation directory in '%s'", image_dir);
        free(image_dir);
        return NULL;
    }

    free(image_dir);
    return inst_dir;
}

// Creates a temporary installation directory in the system's temp directory.
static char *create_temporary_inst_dir(void)
{
    char *temp_dir = GetTempDirectoryPath();
    if (!temp_dir) {
        APP_ERROR("Failed to obtain the temporary directory path");
        return NULL;
    }

    char *inst_dir = create_uniq_dir(temp_dir);
    if (!inst_dir) {
        APP_ERROR("Failed to create installation directory in '%s'", temp_dir);
        free(temp_dir);
        return NULL;
    }

    free(temp_dir);
    return inst_dir;
}

const char *CreateInstDir(bool is_extract_to_exe_dir)
{
    if (InstDir != NULL) {
        APP_ERROR("Installation directory has already been set");
        return NULL;
    }

    char *inst_dir = NULL;

    if (is_extract_to_exe_dir) {
        inst_dir = create_debug_extract_inst_dir();
    } else {
        inst_dir = create_temporary_inst_dir();
    }
    if (!inst_dir) {
        return NULL;
    }

    InstDir = inst_dir;
    return inst_dir;
}

// Frees the allocated memory for the installation directory path.
void FreeInstDir(void)
{
    free(InstDir);
    InstDir = NULL;
}

// Returns the path to the installation directory.
const char *GetInstDir()
{
    if (!IsInstDirSet()) {
        APP_ERROR("Installation directory has not been set");
        return NULL;
    }

    return InstDir;
}

// Concatenates the installation directory path with a relative path.
char *ExpandInstDirPath(const char *rel_path)
{
    if (!IsInstDirSet()) {
        APP_ERROR("Installation directory has not been set");
        return NULL;
    }

    if (!rel_path || !*rel_path) {
        APP_ERROR("relative path is NULL or empty");
        return NULL;
    }

    if (!IsCleanRelativePath(rel_path)) {
        APP_ERROR("invalid relative path '%s'", rel_path);
        return NULL;
    }

    char *full_path = JoinPath(InstDir, rel_path);
    if (!full_path) {
        APP_ERROR("Failed to build full path");
    }
    return full_path;
}

// Deletes the installation directory and all its contents.
bool DeleteInstDir(void)
{
    if (!IsInstDirSet()) {
        APP_ERROR("Installation directory has not been set");
        return false;
    }

    return DeleteRecursively(InstDir);
}

// Replaces placeholders in a string with the installation directory path.
char *ReplaceInstDirPlaceholder(const char *tmpl)
{
    if (!IsInstDirSet()) {
        APP_ERROR("Installation directory has not been set");
        return NULL;
    }

    const char *replacement = InstDir;
    size_t replacement_len = strlen(replacement);
    size_t c = 0;

    for (const char *p = tmpl; *p; p++) { if (*p == PLACEHOLDER) c++; }
    size_t replaced_len = strlen(tmpl) - c + replacement_len * c + 1;
    char *replaced = calloc(replaced_len, sizeof(*replaced));
    if (!replaced) {
        APP_ERROR("Memory allocation failed for placeholder replacement");
        return NULL;
    }

    char *out = replaced;
    for (const char *in = tmpl; *in; in++) {
        if (*in == PLACEHOLDER) {
            memcpy(out, replacement, replacement_len);
            out += replacement_len;
        } else {
            *out = *in;
            out++;
        }
    }
    *out = '\0';

    return replaced;
}

bool CreateDirectoryUnderInstDir(const char *rel_path)
{
    if (!IsInstDirSet()) {
        APP_ERROR("Installation directory has not been set");
        return false;
    }

    if (!rel_path) {
        APP_ERROR("relative path is NULL");
        return false;
    }

    /* Treat empty string as a no-op and return success */
    if (rel_path[0] == '\0') {
        return true;
    }

    char *dir = ExpandInstDirPath(rel_path);
    if (!dir) {
        APP_ERROR("Failed to build full path");
        return false;
    }

    bool result = CreateDirectoriesRecursively(dir);
    if (!result) {
        APP_ERROR(
            "Failed to create directory under installation directory: '%s'",
            dir
        );
    }

    free(dir);
    return result;
}

bool ExportFileToInstDir(const char *rel_path, const void *buf, size_t len)
{
    bool  result = false;
    char *path   = NULL;

    if (!IsInstDirSet()) {
        APP_ERROR("Installation directory has not been set");
        goto cleanup;
    }

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

    if (!ExportFile(path, buf, len)) {
        APP_ERROR("Failed to export file: %s", path);
        goto cleanup;
    }

    result = true;

cleanup:
    if (path) {
        free(path);
    }
    return result;
}

bool SetEnvWithInstDir(const char *name, const char *value)
{
    char *replaced_value = ReplaceInstDirPlaceholder(value);
    if (!replaced_value) {
        APP_ERROR("Failed to replace the value placeholder");
        return false;
    }

    DEBUG("SetEnv(%s, %s)", name, replaced_value);

    bool result = SetEnvVar(name, replaced_value);
    if (!result) {
        APP_ERROR("Failed to set environment variable: %s", name);
    }

    free(replaced_value);
    return result;
}
