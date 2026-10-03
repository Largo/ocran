#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#ifdef __COSMOPOLITAN__
#include <cosmo.h>  /* GetProgramExecutableName(), IsWindows() */
#endif
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/resource.h>
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

/* Keeps going after a failure so that as much as possible gets deleted, and
   returns false if anything could not be. Failures are only reported in
   debug mode: the application has run, and there is nobody to act on them. */
bool DeleteRecursively(const char *path) {
    if (!path || !*path) {
        return false;
    }

    struct stat st;
    if (lstat(path, &st) < 0) {
        APP_ERROR("DeleteRecursively: lstat(\"%s\") failed: %s", path, strerror(errno));
        return false;
    }

    if (!S_ISDIR(st.st_mode)) {
        /* A file or a symlink (which is not followed): just delete it */
        if (unlink(path) < 0) {
            APP_ERROR("DeleteRecursively: unlink(\"%s\") failed: %s", path, strerror(errno));
            return false;
        }
        return true;
    }

    /* Listing a directory and deleting its entries takes read, write and
       search permission, which the application may have removed (e.g. a
       read-only copy of a Go module cache). The directory is the user's
       own, so give them back. */
    if ((st.st_mode & S_IRWXU) != S_IRWXU) {
        chmod(path, (st.st_mode & 07777) | S_IRWXU);
    }

    /* It's a directory, delete contents recursively */
    DIR *dir = opendir(path);
    if (!dir) {
        APP_ERROR("DeleteRecursively: opendir(\"%s\") failed: %s", path, strerror(errno));
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
            continue;
        }

        if (!DeleteRecursively(child_path)) {
            success = false;
        }
        free(child_path);
    }

    closedir(dir);

    if (success) {
        if (rmdir(path) < 0) {
            APP_ERROR("DeleteRecursively: rmdir(\"%s\") failed: %s", path, strerror(errno));
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

    /* Create/overwrite the file, but never write through a symlink that
       happens to sit at its path (the file would land at the link's
       target). O_EXCL would be stricter still, but on a case-insensitive
       file system (the macOS default) it would turn two packed names that
       differ only in case, which merely overwrite each other today, into a
       failed start. */
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0777);
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
#ifdef __COSMOPOLITAN__
    /* Cosmopolitan Libc defines neither __linux__ nor __APPLE__; it resolves
       the executable path itself on every OS the APE binary runs on. */
    const char *exe = GetProgramExecutableName();
    if (!exe || !*exe) {
        FATAL("GetImagePath: GetProgramExecutableName failed");
        return NULL;
    }

    char *result = strdup(exe);
    if (!result) {
        FATAL("GetImagePath: strdup failed");
        return NULL;
    }

    return result;
#else
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
#endif /* __COSMOPOLITAN__ */
}

char *GetTempDirectoryPath(void) {
    const char *tmpdir = getenv("TMPDIR");
#ifdef __COSMOPOLITAN__
    /* On Windows, Cosmopolitan Libc translates the magic "/tmp" prefix to
       a real directory, but WHERE it points differs between cosmo
       releases (%TMP% in some, C:\tmp in others). This stub and the
       packed cosmopolitan Ruby may be built against different cosmo
       versions, so a literal "/tmp/..." extraction path handed to the
       child can resolve to a DIFFERENT directory than the one the stub
       extracted into. TMP/TEMP, by contrast, are presented by cosmo in
       its unambiguous drive-letter form (e.g. /C/Users/x/AppData/Local/
       Temp) that every cosmo runtime resolves identically, so prefer
       them. On POSIX hosts they are normally unset and the usual
       TMPDIR -> /tmp behavior is preserved. */
    if (!tmpdir || !*tmpdir) {
        tmpdir = getenv("TMP");
    }
    if (!tmpdir || !*tmpdir) {
        tmpdir = getenv("TEMP");
    }
#endif
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

/*
 * Termination signals the stub handles while it runs. The handler records
 * the signal and passes it on to the child, so that `kill`, `docker stop`
 * or a service manager stopping the stub stop the application, and the
 * stub lives on to delete the extraction directory. Signals that were
 * ignored when the stub started (e.g. SIGHUP under nohup) stay ignored,
 * and the child inherits that.
 */
static const int TerminationSignals[] = { SIGINT, SIGTERM, SIGHUP, SIGQUIT };
#define TERMINATION_SIGNAL_COUNT \
    (sizeof(TerminationSignals) / sizeof(TerminationSignals[0]))

/* Which of TerminationSignals were ignored at startup. */
static bool SignalIgnoredAtStartup[TERMINATION_SIGNAL_COUNT];

/* Child to forward termination signals to; 0 while there is none. */
static volatile sig_atomic_t ChildPid = 0;

/* Last termination signal the stub received itself. */
static volatile sig_atomic_t ReceivedSignal = 0;

/* Signal the stub dies of once cleanup is done: the one that killed the
   child, or one received before the child was started. */
static int TerminatingSignal = 0;

/* Whether a signal was sent by a process (kill(2), sigqueue(3)) rather than
   generated by the kernel. Signals the kernel raises for a terminal (Ctrl+C,
   Ctrl+\, hangup) go to the whole foreground process group, the child
   included, which must not get them twice. */
#ifdef __APPLE__
/* Whether this process is in the foreground process group of its
   controlling terminal, the only place a terminal-generated signal can
   reach it. Everything here is async-signal-safe. */
static bool in_foreground_process_group(void)
{
    int fd = open("/dev/tty", O_RDONLY | O_NOCTTY | O_CLOEXEC);
    if (fd < 0) {
        return false;
    }
    pid_t foreground = tcgetpgrp(fd);
    close(fd);
    return foreground > 0 && foreground == getpgrp();
}
#endif

static bool is_sent_by_process(const siginfo_t *info)
{
    if (!info) {
        return true;
    }
    if (info->si_code == SI_USER) {
        return true;
    }
#ifdef __APPLE__
    /* XNU never reports SI_USER: every caught signal arrives with si_code 0
       and si_pid naming the process in whose context it was raised, for
       kill(2) and for the terminal driver alike (bsd/kern/kern_sig.c), so
       siginfo cannot tell them apart. A terminal signal only reaches the
       foreground process group of the controlling terminal; a stub running
       anywhere else - no terminal, a background job, a service, a CI runner
       - can only have been signaled by a process. */
    if (info->si_code == 0) {
        return !in_foreground_process_group();
    }
#endif
#ifdef SI_QUEUE
    if (info->si_code == SI_QUEUE) {
        return true;
    }
#endif
#ifdef SI_TKILL
    if (info->si_code == SI_TKILL) {
        return true;
    }
#endif
    return false;
}

static void termination_signal_handler(int sig, siginfo_t *info, void *context)
{
    (void)context;
    int saved_errno = errno;

    ReceivedSignal = sig;
    pid_t child = (pid_t)ChildPid;
    if (child > 0 && is_sent_by_process(info)) {
        kill(child, sig);
    }

    errno = saved_errno;
}

bool InitializeSignalHandling(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = termination_signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    for (size_t i = 0; i < TERMINATION_SIGNAL_COUNT; i++) {
        sigaddset(&sa.sa_mask, TerminationSignals[i]);
    }

    for (size_t i = 0; i < TERMINATION_SIGNAL_COUNT; i++) {
        int sig = TerminationSignals[i];
        struct sigaction old;

        if (sigaction(sig, NULL, &old) < 0) {
            FATAL("InitializeSignalHandling: sigaction(%d) failed: %s", sig, strerror(errno));
            return false;
        }
        if (!(old.sa_flags & SA_SIGINFO) && old.sa_handler == SIG_IGN) {
            SignalIgnoredAtStartup[i] = true;
            continue;
        }
        if (sigaction(sig, &sa, NULL) < 0) {
            FATAL("InitializeSignalHandling: sigaction(%d) failed: %s", sig, strerror(errno));
            return false;
        }
    }

    return true;
}

static void (*CleanupRoutine)(void) = NULL;
static bool CleanupDone = false;

void SetCleanupRoutine(void (*routine)(void))
{
    CleanupRoutine = routine;
}

/* Only ever called from the main thread here: signal handlers merely
   forward, and the main thread outlives the child to clean up. */
void RunCleanupRoutine(void)
{
    if (CleanupDone) {
        return;
    }
    CleanupDone = true;
    if (CleanupRoutine) {
        CleanupRoutine();
    }
}

void ReraiseChildSignal(void)
{
    int sig = TerminatingSignal;
    if (sig == 0) {
        return;
    }

#ifdef __COSMOPOLITAN__
    /* A native Windows parent cannot see a signal death; it gets the
       128 + signal exit code instead (see the end of main()). */
    if (IsWindows()) {
        return;
    }
#endif

    DEBUG("Terminating with signal %d like the application", sig);
    fflush(NULL);

    /* The application dumped core already if it was going to. */
    struct rlimit no_core = { 0, 0 };
    setrlimit(RLIMIT_CORE, &no_core);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, NULL);

    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, sig);
    sigprocmask(SIG_UNBLOCK, &set, NULL);

    raise(sig);

    /* Still alive: e.g. PID 1 of a container, for which the kernel drops
       signals whose action is the default. The caller exits with
       128 + signal instead. */
    DEBUG("Signal %d did not terminate the stub", sig);
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

    /* Hold termination signals until ChildPid is set, so that none arriving
       around fork() gets lost. */
    sigset_t term_set, orig_mask;
    sigemptyset(&term_set);
    for (size_t i = 0; i < TERMINATION_SIGNAL_COUNT; i++) {
        sigaddset(&term_set, TerminationSignals[i]);
    }
    sigprocmask(SIG_BLOCK, &term_set, &orig_mask);

    /* Asked to terminate during extraction: do not start the application. */
    if (ReceivedSignal) {
        TerminatingSignal = ReceivedSignal;
        *exit_code = 128 + TerminatingSignal;
        DEBUG("Received signal %d before the application started", TerminatingSignal);
        sigprocmask(SIG_SETMASK, &orig_mask, NULL);
        return true;
    }

    pid_t pid = fork();
    if (pid < 0) {
        FATAL("CreateAndWaitForProcess: fork() failed: %s", strerror(errno));
        sigprocmask(SIG_SETMASK, &orig_mask, NULL);
        return false;
    }

    if (pid == 0) {
        /* Child process: restore the signal handling the stub was started
           with, then execute the target application. */
        for (size_t i = 0; i < TERMINATION_SIGNAL_COUNT; i++) {
            signal(TerminationSignals[i],
                   SignalIgnoredAtStartup[i] ? SIG_IGN : SIG_DFL);
        }
        sigprocmask(SIG_SETMASK, &orig_mask, NULL);

        execv(app_name, argv);

        /* If we get here, execv failed. _exit, not exit: atexit handlers
           and stdio buffers belong to the parent. */
        FATAL("CreateAndWaitForProcess: execv(\"%s\") failed: %s", app_name, strerror(errno));
        _exit(127);
    }

    /* Parent process */
    ChildPid = pid;
    sigprocmask(SIG_SETMASK, &orig_mask, NULL);

    int wstatus;
    pid_t waited;
    do {
        waited = waitpid(pid, &wstatus, 0);
    } while (waited < 0 && errno == EINTR);
    ChildPid = 0;

    if (waited < 0) {
        FATAL("CreateAndWaitForProcess: waitpid failed: %s", strerror(errno));
        return false;
    }

    if (WIFEXITED(wstatus)) {
        *exit_code = WEXITSTATUS(wstatus);
    } else if (WIFSIGNALED(wstatus)) {
        TerminatingSignal = WTERMSIG(wstatus);
        *exit_code = 128 + TerminatingSignal;
        DEBUG("The application was terminated by signal %d", TerminatingSignal);
    } else {
        *exit_code = 1;
    }

    return true;
}

/* POSIX has no short-path aliases - return a plain copy. */
char *ToLongPath(const char *path)
{
    return path ? strdup(path) : NULL;
}
