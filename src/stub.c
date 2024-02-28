/*
  Single Executable Bundle Stub
  This stub reads itself for embedded instructions to create directory
  and files in a temporary directory, launching a program.
*/

#include <windows.h>
#include <string.h>
#include <stdio.h>
#include "error.h"
#include "filesystem_utils.h"
#include "stub.h"
#include "unpack.h"

const BYTE Signature[] = { 0x41, 0xb6, 0xba, 0x4e };

BOOL ProcessImage(LPVOID pSeg, DWORD data_len, BOOL compressed);
DWORD CreateAndWaitForProcess(const char *app_name, char *cmd_line);

#if WITH_LZMA
#include <LzmaDec.h>

#define LZMA_UNPACKSIZE_SIZE 8

ULONGLONG GetDecompressionSize(void *src)
{
    ULONGLONG size = 0;

    for (int i = 0; i < LZMA_UNPACKSIZE_SIZE; i++)
        size += ((BYTE *)src)[LZMA_PROPS_SIZE + i] << (i * 8);

    return size;
}

#define LZMA_HEADER_SIZE (LZMA_PROPS_SIZE + LZMA_UNPACKSIZE_SIZE)

void *SzAlloc(const ISzAlloc *p, size_t size) { p = p; return LocalAlloc(LMEM_FIXED, size); }
void SzFree(const ISzAlloc *p, void *address) { p = p; LocalFree(address); }
ISzAlloc alloc = { SzAlloc, SzFree };

BOOL DecompressLzma(void *unpack_data, size_t unpack_size, void *src, size_t src_size)
{
    SizeT lzmaDecompressedSize = unpack_size;
    SizeT inSizePure = src_size - LZMA_HEADER_SIZE;
    ELzmaStatus status;

    SRes res = LzmaDecode((Byte *)unpack_data, &lzmaDecompressedSize, (Byte *)src + LZMA_HEADER_SIZE, &inSizePure,
                          (Byte *)src, LZMA_PROPS_SIZE, LZMA_FINISH_ANY, &status, &alloc);

    return (BOOL)(res == SZ_OK);
}
#endif

char *Script_ApplicationName = NULL;
char *Script_CommandLine = NULL;

char InstDir[MAX_PATH];

char* ConcatStr(const char *first, ...) {
    va_list args;
    va_start(args, first);
    size_t len = 0;
    for (const char* s = first; s; s = va_arg(args, const char*)) {
        len += strlen(s);
    }
    va_end(args);

    char *str = LocalAlloc(LPTR, len + 1);

    if (str == NULL) {
        LAST_ERROR("Failed to allocate memory");
        return NULL;
    }

    va_start(args, first);
    char *p = str;
    for (const char *s = first; s; s = va_arg(args, const char*)) {
        size_t l = strlen(s);
        memcpy(p, s, l);
        p += l;
    }
    str[len] = '\0';
    va_end(args);

    return str;
}

char *ExpandInstDirPath(const char *rel_path)
{
    if (rel_path == NULL || *rel_path == '\0') {
        DEBUG("rel_path is null or empty");
        return NULL;
    }

    return JoinPath(InstDir, rel_path);
}

BOOL CheckInstDirPathExists(const char *rel_path)
{
    char *path = ExpandInstDirPath(rel_path);
    BOOL result = (GetFileAttributes(path) != INVALID_FILE_ATTRIBUTES);
    LocalFree(path);

    return result;
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

#define DELETION_MAKER_SUFFIX ".ocran-delete-me"

void MarkInstDirForDeletion(void)
{
    char *marker = ConcatStr(InstDir, DELETION_MAKER_SUFFIX, NULL);

    if (marker == NULL) {
        FATAL("Marker is null");
        return;
    }

    HANDLE h = CreateFile(marker, 0, 0, NULL, CREATE_ALWAYS, 0, NULL);

    if (h == INVALID_HANDLE_VALUE) {
        LAST_ERROR("Failed to mark for deletion");
    }

    FATAL("Deletion marker path is %s", marker);
    CloseHandle(h);
    LocalFree(marker);
}

BOOL CreateInstDirectory(BOOL debug_extract)
{
    /* Create an installation directory that will hold the extracted files */
    char *target_dir = NULL;

    if (debug_extract) {
        // In debug extraction mode, create the temp directory next to the exe
        char *image_dir = GetImageDirectoryPath();
        if (image_dir == NULL) {
            FATAL("Failed to obtain the directory path of the executable file");
            return FALSE;
        }
        target_dir = image_dir;
    } else {
        char *temp_dir = GetTempDirectoryPath();
        if (temp_dir == NULL) {
            FATAL("Failed to obtain the temporary directory path");
            return FALSE;
        }
        target_dir = temp_dir;
    }

    DEBUG("Creating installation directory: %s", target_dir);

    char *inst_dir = CreateUniqueDirectory(target_dir, "ocran");
    LocalFree(target_dir);
    if (inst_dir == NULL) {
        FATAL("Failed to create a unique installation directory within the specified target directory");
        return FALSE;
    }

    DEBUG("Created installation directory: %s", inst_dir);

    if ((strlen(inst_dir) + 1) > MAX_PATH) {
        FATAL("Installation directory path exceeds the MAX_PATH limit");
        LocalFree(inst_dir);
        return FALSE;
    }

    strcpy(InstDir, inst_dir);
    return TRUE;
}

int CALLBACK WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
    DWORD exit_code = 0;

    /* Find name of image */
    char *image_path = GetImagePath();
    if (image_path == NULL) {
        return LAST_ERROR("Failed to get executable name");
    }

   SetConsoleCtrlHandler(&ConsoleHandleRoutine, TRUE);

    /* Open the image (executable) */
    HANDLE hImage = CreateFile(image_path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (hImage == INVALID_HANDLE_VALUE) {
        return LAST_ERROR("Failed to open executable file");
    }

    /* Create a file mapping */
    DWORD image_size = GetFileSize(hImage, NULL);
    HANDLE hMem = CreateFileMapping(hImage, NULL, PAGE_READONLY, 0, image_size, NULL);
    if (hMem == INVALID_HANDLE_VALUE) {
        return LAST_ERROR("Failed to create file mapping");
    }

    /* Map the image into memory */
    LPVOID lpv = MapViewOfFile(hMem, FILE_MAP_READ, 0, 0, 0);
    if (lpv == NULL) {
        return LAST_ERROR("Failed to map view of executable into memory");
    }

    /* Process the image by checking the signature and locating the first opcode */
    void *sig = lpv + image_size - sizeof(Signature);

    if (memcmp(sig, Signature, sizeof(Signature)) != 0) {
        return FATAL("Bad signature in executable");
    }

    void *tail = sig - sizeof(DWORD);
    DWORD OpcodeOffset = *(DWORD*)(tail);
    void *head = lpv + OpcodeOffset;

    /* Read header of packed data */
    OperationModes flags = (OperationModes)*(BYTE *)head; head++;

    DebugModeEnabled = IS_DEBUG_MODE_ENABLED(flags);

    if (DebugModeEnabled) {
        DEBUG("Ocran stub running in debug mode");
    }

    if (!CreateInstDirectory(IS_EXTRACT_TO_EXE_DIR_ENABLED(flags))) {
        return FATAL("Failed to create installation directory");
    }

    /* Unpacking process */
    if (!ProcessImage(head, tail - head, IS_DATA_COMPRESSED(flags))) {
        exit_code = EXIT_CODE_FAILURE;
    }

    /* Release resources used for image reading */
    if (!UnmapViewOfFile(lpv)) {
        exit_code = LAST_ERROR("Failed to unmap view of executable");
    } else if (!CloseHandle(hMem)) {
        exit_code = LAST_ERROR("Failed to close file mapping");
    } else if (!CloseHandle(hImage)) {
        exit_code = LAST_ERROR("Failed to close executable");
    }

    /* Launching the script, provided there are no errors in file extraction from the image */
    if (exit_code == 0 && Script_ApplicationName && Script_CommandLine) {
        DEBUG("*** Starting app in %s", InstDir);

        if (IS_CHDIR_BEFORE_SCRIPT_ENABLED(flags)) {
            DEBUG("Changing CWD to unpacked directory %s/src", InstDir);

            char *script_dir = ExpandInstDirPath("src");

            if (!SetCurrentDirectory(script_dir)) {
                exit_code = LAST_ERROR("Failed to change CWD");
            }

            LocalFree(script_dir);
        }

        if (exit_code == 0) {
            if (!SetEnvironmentVariable("OCRAN_EXECUTABLE", image_path)) {
                exit_code = LAST_ERROR("Failed to set environment variable");
            } else {
                exit_code = CreateAndWaitForProcess(Script_ApplicationName, Script_CommandLine);
            }
        }
    }

    LocalFree(Script_ApplicationName);
    Script_ApplicationName = NULL;

    LocalFree(Script_CommandLine);
    Script_CommandLine = NULL;

    /* If necessary, recursively delete the installation directory */
    if (IS_AUTO_CLEAN_INST_DIR_ENABLED(flags)) {
      DEBUG("Deleting temporary installation directory %s", InstDir);
      char SystemDirectory[MAX_PATH];
      if (GetSystemDirectory(SystemDirectory, MAX_PATH) > 0)
         SetCurrentDirectory(SystemDirectory);
      else
         SetCurrentDirectory("C:\\");

      if (!DeleteRecursively(InstDir))
            MarkInstDirForDeletion();
    }

    return exit_code;
}

BOOL ProcessImage(LPVOID pSeg, DWORD data_len, BOOL compressed)
{
    BYTE last_opcode;

    if (compressed) {
#if WITH_LZMA
        DEBUG("LzmaDecode(%ld)", data_len);

        ULONGLONG unpack_size = GetDecompressionSize(pSeg);
        if (unpack_size > (ULONGLONG)(DWORD)-1) {
            FATAL("Decompression size is too large.");
            return FALSE;
        }

        LPVOID unpack_data = LocalAlloc(LMEM_FIXED, unpack_size);
        if (unpack_data == NULL) {
            LAST_ERROR("LocalAlloc failed");
            return FALSE;
        }

        if (!DecompressLzma(unpack_data, unpack_size, pSeg, data_len)) {
            FATAL("LZMA decompression failed.");
            LocalFree(unpack_data);
            return FALSE;
        }

        LPVOID p = unpack_data;
        last_opcode = ProcessOpcodes(&p);
        LocalFree(unpack_data);
#else
        FATAL("Does not support LZMA");
        return FALSE;
#endif
    } else {
        last_opcode = ProcessOpcodes(&pSeg);
    }

    if (last_opcode != OP_END) {
        FATAL("Invalid opcode '%u'.", last_opcode);
        return FALSE;
    }
    return TRUE;
}

/**
   Expands a specially formatted string, replacing | with the
   temporary installation directory.
*/

#define PLACEHOLDER '|'

char *ReplaceInstDirPlaceholder(const char *str)
{
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

/**
   Finds the start of the first argument after the current one. Handles quoted arguments.
*/
char *SkipArg(char *str)
{
   if (*str == '"')
   {
      str++;
      while (*str && *str != '"') { str++; }
      if (*str == '"') { str++; }
   }
   else
   {
      while (*str && *str != ' ') { str++; }
   }
   while (*str && *str != ' ') { str++; }
   return str;
}

/**
   Create a file (OP_CREATE_FILE opcode handler)
*/
BOOL MakeFile(const char *file_name, size_t file_size, const void *data)
{
    if (file_name == NULL || *file_name == '\0') {
        FATAL("file_name is null or empty");
        return FALSE;
    }

    char *path = ExpandInstDirPath(file_name);

    if (path == NULL) {
        FATAL("Failed to expand path to installation directory");
        return FALSE;
    }

    DEBUG("CreateFile(%s)", path);

    if (!CreateParentDirectories(path)) {
        FATAL("Failed to create parent directory");
        LocalFree(path);
        return FALSE;
    }

    BOOL result = TRUE;
    HANDLE h = CreateFile(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);

    if (h != INVALID_HANDLE_VALUE) {
        DWORD BytesWritten;

        DEBUG("Write data(%lu)", file_size);

        if (!WriteFile(h, data, (DWORD)file_size, &BytesWritten, NULL)) {
            LAST_ERROR("Write failure");
            result = FALSE;
        }

        if (BytesWritten != file_size) {
            FATAL("Write size failure");
            result = FALSE;
        }

        CloseHandle(h);
    } else {
        LAST_ERROR("Failed to create file");
        result = FALSE;
    }

    LocalFree(path);

    return result;
}

/**
   Create a directory (OP_CREATE_DIRECTORY opcode handler)
*/
BOOL MakeDirectory(const char *dir_name)
{
    DEBUG("MakeDirectory");

    if (dir_name == NULL || *dir_name == '\0') {
        DEBUG("dir_name is NULL or empty");
        return FALSE;
    }

    char *dir = ExpandInstDirPath(dir_name);

    if (dir == NULL) {
        FATAL("Failed to expand dir_name to installation directory");
        return FALSE;
    }

    BOOL result = CreateDirectoriesRecursively(dir);

    LocalFree(dir);
    return result;
}

DWORD CreateAndWaitForProcess(const char *app_name, char *cmd_line)
{
    PROCESS_INFORMATION p_info;
    ZeroMemory(&p_info, sizeof(p_info));
    STARTUPINFO s_info;
    ZeroMemory(&s_info, sizeof(s_info));
    s_info.cb = sizeof(s_info);

    DEBUG("Create process (%s, %s)", app_name, cmd_line);

    if (!CreateProcess(app_name, cmd_line, NULL, NULL, TRUE, 0, NULL, NULL, &s_info, &p_info)) {
        return LAST_ERROR("Failed to create process");
    }

    WaitForSingleObject(p_info.hProcess, INFINITE);

    DWORD exit_code;

    if (!GetExitCodeProcess(p_info.hProcess, &exit_code)) {
        exit_code = LAST_ERROR("Failed to get exit status");
    }

    CloseHandle(p_info.hProcess);
    CloseHandle(p_info.hThread);
    return exit_code;
}

char *EscapeAndQuoteCmdArg(const char* arg)
{
    size_t arg_len = strlen(arg);
    size_t count = 0;
    for (size_t i = 0; i < arg_len; i++) { if (arg[i] == '\"') count++; }
    char *sanitized = (char *)LocalAlloc(LPTR, arg_len + count * 2 + 3);
    if (sanitized == NULL) {
        LAST_ERROR("Failed to allocate memory");
        return NULL;
    }

    char *p = sanitized;
    *p++ = '\"';
    for (size_t i = 0; i < arg_len; i++) {
        if (arg[i] == '\"') { *p++ = '\\'; }
        *p++ = arg[i];
    }
    *p++ = '\"';
    *p = '\0';

    return sanitized;
}

BOOL ParseArguments(const char *args, size_t args_size, size_t *out_argc, const char ***out_argv) {
    size_t local_argc = 0;
    for (const char *s = args; s < (args + args_size); s += strlen(s) + 1) {
        local_argc++;
    }

    const char **local_argv = (const char **)LocalAlloc(LPTR, (local_argc + 1) * sizeof(char *));
    if (local_argv == NULL) {
        FATAL("Failed to memory allocate for argv");
        return FALSE;
    }

    const char *s = args;
    for (size_t i = 0; i < local_argc; i++) {
        local_argv[i] = s;
        s += strlen(s) + 1;
    }
    local_argv[local_argc] = NULL;

    *out_argc = local_argc;
    *out_argv = local_argv;
    return TRUE;
}

char *BuildCommandLine(size_t argc, const char *argv[])
{
    char *command_line = EscapeAndQuoteCmdArg(argv[0]);
    if (command_line == NULL) {
        FATAL("Failed to initialize command line with first arg");
        return NULL;
    }

    for (size_t i = 1; i < argc; i++) {
        char *str;
        if (i == 1) {
            str = ExpandInstDirPath(argv[1]);
            if (str == NULL) {
                FATAL("Failed to expand script name to installation directory at arg index 1");
                goto cleanup;
            }
        } else {
            str = ReplaceInstDirPlaceholder(argv[i]);
            if (str == NULL) {
                FATAL("Failed to replace arg placeholder at arg index %d", i);
                goto cleanup;
            }
        }

        char *sanitized = EscapeAndQuoteCmdArg(str);
        LocalFree(str);
        if (sanitized == NULL) {
            FATAL("Failed to sanitize arg at arg index %d", i);
            goto cleanup;
        }
        char *base = command_line;
        command_line = ConcatStr(base, " ", sanitized, NULL);
        LocalFree(base);
        LocalFree(sanitized);
        if (command_line == NULL) {
            FATAL("Failed to build command line after adding arg at arg index %d", i);
            goto cleanup;
        }
    }

    return command_line;

cleanup:
    LocalFree(command_line);

    return NULL;
}

/**
 * Sets up a process to be created after all other opcodes have been processed. This can be used to create processes
 * after the temporary files have all been created and memory has been freed.
 */
BOOL SetScript(const char *args, size_t args_size)
{
    DEBUG("SetScript");

    if (Script_ApplicationName || Script_CommandLine) {
        FATAL("Script is already set");
        return FALSE;
    }

    size_t argc;
    const char **argv = NULL;
    if (!ParseArguments(args, args_size, &argc, &argv)) {
        FATAL("Failed to parse arguments");
        return FALSE;
    }

    /**
     * Set Script_ApplicationName
     */
    Script_ApplicationName = ExpandInstDirPath(argv[0]);
    if (Script_ApplicationName == NULL) {
        FATAL("Failed to expand application name to installation directory");
        LocalFree(argv);
        return FALSE;
    }

    /**
     * Set Script_CommandLine
     */
    char *command_line = BuildCommandLine(argc, argv);
    if (command_line == NULL) {
        FATAL("Failed to build command line");
        LocalFree(argv);
        return FALSE;
    }

    char *MyArgs = SkipArg(GetCommandLine());

    Script_CommandLine = ConcatStr(command_line, " ", MyArgs, NULL);
    LocalFree(argv);
    LocalFree(command_line);
    if (Script_CommandLine == NULL) {
        FATAL("Failed to build command line");
        return FALSE;
    }

    return TRUE;
}

BOOL SetEnv(const char *name, const char *value)
{
    char *replaced_value = ReplaceInstDirPlaceholder(value);

    if (replaced_value == NULL) {
        FATAL("Failed to replace the value placeholder");
        return FALSE;
    }

    DEBUG("SetEnv(%s, %s)", name, replaced_value);

    BOOL result = SetEnvironmentVariable(name, replaced_value);

    if (!result)
        LAST_ERROR("Failed to set environment variable");

    LocalFree(replaced_value);

    return result;
}
