/*
 * Path string helpers shared by the Windows (system_utils.c) and POSIX
 * (system_utils_posix.c) builds. Pure string manipulation: nothing here
 * touches the file system.
 */

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#ifdef __COSMOPOLITAN__
#include <cosmo.h>  /* IsWindows() */
#endif
#include "error.h"
#include "system_utils.h"

bool IsCleanRelativePath(const char *path)
{
    if (!path || !*path) {
        return false;
    }

#ifdef _WIN32
    /* Forbid Windows drive specification (e.g. "C:\") */
    if (((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z'))
        && path[1] == ':'
        && is_path_separator(path[2])) {
        return false;
    }
#endif

    /* Forbid absolute path (leading '/' or '\') */
    if (is_path_separator(*path)) {
        return false;
    }

#ifdef __COSMOPOLITAN__
    /* A cosmopolitan stub splits paths at '/' only, but on Windows the
       path ends up with the Win32 API, which splits at '\' as well: a
       name like "..\x" would pass below as a single segment and then
       climb out of the extraction directory. The packer never emits a
       backslash in a name, so refuse all of them there. */
    if (IsWindows() && strchr(path, '\\')) {
        return false;
    }
#endif

    /* Validate each path segment */
    const char *p = path;
    while (*p) {
        const char *start = p;

        /* Advance until next separator or end-of-string */
        while (*p && !is_path_separator(*p)) {
            p++;
        }

        size_t len = p - start;

        /* Reject empty, "." or ".." segments */
        if (len == 0
            || (len == 1 && start[0] == '.')
            || (len == 2 && start[0] == '.' && start[1] == '.')) {
            return false;
        }

        /* Skip over the separator */
        if (*p) {
            p++;
        }
    }

    return true;
}

// Combines two file path components into a single path, handling path separators.
char *JoinPath(const char *p1, const char *p2)
{
    if (p1 == NULL || *p1 == '\0') {
        APP_ERROR("p1 is null or empty");
        return NULL;
    }

    if (p2 == NULL || *p2 == '\0') {
        APP_ERROR("p2 is null or empty");
        return NULL;
    }

    size_t p1_len = strlen(p1);
    if (is_path_separator(p1[p1_len - 1])) { p1_len--; }

    size_t p2_len = strlen(p2);
    const char *p2_start = p2;
    if (is_path_separator(*p2_start)) { p2_start++; p2_len--; }

    size_t joined_len = p1_len + 1 + p2_len;
    char *joined_path = calloc(1, joined_len + 1);
    if (!joined_path) {
        APP_ERROR("Failed to allocate buffer for join path");
        return NULL;
    }
    memcpy(joined_path, p1, p1_len);
    joined_path[p1_len] = PATH_SEPARATOR;
    memcpy(joined_path + p1_len + 1, p2_start, p2_len);
    joined_path[joined_len] = '\0';

    return joined_path;
}

char *GetParentPath(const char *path)
{
    if (!path) {
        APP_ERROR("path is NULL");
        return NULL;
    }

    size_t root = path_root_length(path);
    size_t i    = strlen(path);

    /* Skip any trailing separators */
    while (i > root && is_path_separator(path[i - 1])) {
        i--;
    }

    /* Skip the last segment's characters */
    while (i > root && !is_path_separator(path[i - 1])) {
        i--;
    }

    /* Skip the separators before it, keeping the root ("/" or "C:\") */
    while (i > root && is_path_separator(path[i - 1])) {
        i--;
    }

    /* i==0 ⇒ empty parent (relative path with a single segment) */

    char *out = malloc(i + 1);
    if (!out) {
        APP_ERROR("Memory allocation failed for parent path");
        return NULL;
    }
    memcpy(out, path, i);
    out[i] = '\0';
    return out;
}
