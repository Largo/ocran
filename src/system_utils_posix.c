#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <dirent.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <stdbool.h>
#include "error.h"
#include "system_utils.h"

/* Opaque handle for memory-mapped files */
struct MemoryMap {
    int fd;
    void *base;
    size_t size;
};

/* ===== Cross-platform path utilities (from system_utils.c) ===== */

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

    size_t len = strlen(path);
    size_t i   = len;

    /* Skip any trailing separators */
    while (i > 0 && is_path_separator(path[i])) {
        i--;
    }

    /* Skip the last segment's characters */
    while (i > 0 && !is_path_separator(path[i])) {
        i--;
    }

    /* i==0 ⇒ empty parent */

    char *out = malloc(i + 1);
    if (!out) {
        APP_ERROR("Memory allocation failed for parent path");
        return NULL;
    }
    memcpy(out, path, i);
    out[i] = '\0';
    return out;
}

/* ===== Memory-mapped file I/O ===== */

MemoryMap *CreateMemoryMap(const char *path) {
    if (!path) {
        FATAL("CreateMemoryMap: path is NULL");
        return NULL;
    }

    MemoryMap *map = malloc(sizeof(MemoryMap));
    if (!map) {
        FATAL("CreateMemoryMap: malloc failed");
        return NULL;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        FATAL("CreateMemoryMap: open(\"%s\") failed: %s", path, strerror(errno));
        free(map);
        return NULL;
    }

    struct stat st;
    if (fstat(fd, &st) < 0) {
        FATAL("CreateMemoryMap: fstat failed: %s", strerror(errno));
        close(fd);
        free(map);
        return NULL;
    }

    size_t size = (size_t)st.st_size;
    void *base = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (base == MAP_FAILED) {
        FATAL("CreateMemoryMap: mmap failed: %s", strerror(errno));
        close(fd);
        free(map);
        return NULL;
    }

    map->fd = fd;
    map->base = base;
    map->size = size;
    return map;
}

void DestroyMemoryMap(MemoryMap *map) {
    if (!map) {
        FATAL("DestroyMemoryMap: map is NULL");
        return;
    }

    if (map->base && map->size > 0) {
        munmap(map->base, map->size);
    }
    if (map->fd >= 0) {
        close(map->fd);
    }
    free(map);
}

void *GetMemoryMapBase(const MemoryMap *map) {
    return map ? map->base : NULL;
}

size_t GetMemoryMapSize(const MemoryMap *map) {
    return map ? map->size : 0;
}

/* ===== File and directory operations ===== */

bool CreateDirectoriesRecursively(const char *dir) {
    if (!dir || !*dir) {
        return false;
    }

    /* Check if directory already exists */
    struct stat st;
    if (stat(dir, &st) == 0) {
        if (S_ISDIR(st.st_mode)) {
            return true;
        }
        FATAL("CreateDirectoriesRecursively: \"%s\" exists but is not a directory", dir);
        return false;
    }

    /* Create parent directory recursively */
    char *parent = GetParentPath(dir);
    if (parent && *parent) {
        if (!CreateDirectoriesRecursively(parent)) {
            free(parent);
            return false;
        }
        free(parent);
    }

    /* Create this directory */
    if (mkdir(dir, 0755) < 0) {
        if (errno == EEXIST) {
            return true;  /* Race condition: created by another thread */
        }
        FATAL("CreateDirectoriesRecursively: mkdir(\"%s\") failed: %s", dir, strerror(errno));
        return false;
    }

    return true;
}

bool DeleteRecursively(const char *path) {
    if (!path || !*path) {
        return false;
    }

    struct stat st;
    if (lstat(path, &st) < 0) {
        FATAL("DeleteRecursively: stat(\"%s\") failed: %s", path, strerror(errno));
        return false;
    }

    if (!S_ISDIR(st.st_mode)) {
        /* It's a file, just delete it */
        if (unlink(path) < 0) {
            FATAL("DeleteRecursively: unlink(\"%s\") failed: %s", path, strerror(errno));
            return false;
        }
        return true;
    }

    /* It's a directory, delete contents recursively */
    DIR *dir = opendir(path);
    if (!dir) {
        FATAL("DeleteRecursively: opendir(\"%s\") failed: %s", path, strerror(errno));
        return false;
    }

    bool success = true;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }

        char *child_path = JoinPath(path, entry->d_name);
        if (!child_path) {
            success = false;
            break;
        }

        if (!DeleteRecursively(child_path)) {
            free(child_path);
            success = false;
            break;
        }
        free(child_path);
    }

    closedir(dir);

    if (success) {
        if (rmdir(path) < 0) {
            FATAL("DeleteRecursively: rmdir(\"%s\") failed: %s", path, strerror(errno));
            return false;
        }
    }

    return success;
}

char *CreateUniqueDirectory(char *tmpl) {
    if (!tmpl) {
        return NULL;
    }

    char *result = mkdtemp(tmpl);
    if (!result) {
        FATAL("CreateUniqueDirectory: mkdtemp failed: %s", strerror(errno));
        return NULL;
    }

    return result;
}

bool ExportFile(const char *path, const void *buffer, size_t buffer_size) {
    if (!path || !buffer) {
        FATAL("ExportFile: path or buffer is NULL");
        return false;
    }

    /* Create parent directories if needed */
    char *parent = GetParentPath(path);
    if (parent && *parent) {
        if (!CreateDirectoriesRecursively(parent)) {
            free(parent);
            return false;
        }
        free(parent);
    }

    /* Create/overwrite the file */
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0777);
    if (fd < 0) {
        FATAL("ExportFile: open(\"%s\") failed: %s", path, strerror(errno));
        return false;
    }

    size_t written = 0;
    while (written < buffer_size) {
        ssize_t n = write(fd, (const char *)buffer + written, buffer_size - written);
        if (n < 0) {
            FATAL("ExportFile: write(\"%s\") failed: %s", path, strerror(errno));
            close(fd);
            return false;
        }
        written += n;
    }

    close(fd);
    return true;
}

/* ===== Path utilities ===== */

char *GetImagePath(void) {
    static char path_buffer[4096];
#ifdef __APPLE__
    uint32_t size = sizeof(path_buffer);
    if (_NSGetExecutablePath(path_buffer, &size) != 0) {
        FATAL("GetImagePath: _NSGetExecutablePath failed");
        return NULL;
    }
#elif defined(__linux__)
    /* On Linux, the running executable can be found via /proc/self/exe */
    ssize_t len = readlink("/proc/self/exe", path_buffer, sizeof(path_buffer) - 1);

    if (len < 0) {
        FATAL("GetImagePath: readlink(\"/proc/self/exe\") failed: %s", strerror(errno));
        return NULL;
    }
    path_buffer[len] = '\0';
#else
#error "GetImagePath not implemented for this platform"
#endif

    char *result = malloc(strlen(path_buffer) + 1);
    if (!result) {
        FATAL("GetImagePath: malloc failed");
        return NULL;
    }

    strcpy(result, path_buffer);
    return result;
}

char *GetTempDirectoryPath(void) {
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir || !*tmpdir) {
        tmpdir = "/tmp";
    }

    size_t len = strlen(tmpdir);
    char *result = malloc(len + 1);
    if (!result) {
        FATAL("GetTempDirectoryPath: malloc failed");
        return NULL;
    }

    strcpy(result, tmpdir);
    return result;
}

/* ===== Process and signal handling ===== */

bool InitializeSignalHandling(void) {
    /* On POSIX systems, the parent process ignores SIGINT and SIGTERM during
       initialization and cleanup. The child process will reset these to
       SIG_DFL before execv-ing the target application. */

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_IGN;

    if (sigaction(SIGINT, &sa, NULL) < 0) {
        FATAL("InitializeSignalHandling: sigaction(SIGINT) failed: %s", strerror(errno));
        return false;
    }

    if (sigaction(SIGTERM, &sa, NULL) < 0) {
        FATAL("InitializeSignalHandling: sigaction(SIGTERM) failed: %s", strerror(errno));
        return false;
    }

    return true;
}

bool SetEnvVar(const char *name, const char *value) {
    if (!name) {
        FATAL("SetEnvVar: name is NULL");
        return false;
    }

    if (value == NULL) {
        /* Remove the variable */
        if (unsetenv(name) < 0) {
            FATAL("SetEnvVar: unsetenv(\"%s\") failed: %s", name, strerror(errno));
            return false;
        }
    } else {
        if (setenv(name, value, 1) < 0) {
            FATAL("SetEnvVar: setenv(\"%s\", ...) failed: %s", name, strerror(errno));
            return false;
        }
    }

    return true;
}

bool CreateAndWaitForProcess(const char *app_name, char *argv[], int *exit_code) {
    if (!app_name || !argv || !exit_code) {
        FATAL("CreateAndWaitForProcess: app_name, argv, or exit_code is NULL");
        return false;
    }

    pid_t pid = fork();
    if (pid < 0) {
        FATAL("CreateAndWaitForProcess: fork() failed: %s", strerror(errno));
        return false;
    }

    if (pid == 0) {
        /* Child process */

        /* Reset signal handlers to default before exec */
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);

        /* Execute the target application */
        execv(app_name, argv);

        /* If we get here, execv failed */
        FATAL("CreateAndWaitForProcess: execv(\"%s\") failed: %s", app_name, strerror(errno));
        exit(127);
    }

    /* Parent process */

    int wstatus;
    if (waitpid(pid, &wstatus, 0) < 0) {
        FATAL("CreateAndWaitForProcess: waitpid failed: %s", strerror(errno));
        return false;
    }

    if (WIFEXITED(wstatus)) {
        *exit_code = WEXITSTATUS(wstatus);
    } else if (WIFSIGNALED(wstatus)) {
        *exit_code = 128 + WTERMSIG(wstatus);
    } else {
        *exit_code = 1;
    }

    return true;
}
