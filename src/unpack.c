#include <windows.h>
#include <string.h>
#include "error.h"
#include "filesystem_utils.h"
#include "inst_dir.h"
#include "script_info.h"
#include "unpack.h"

#if WITH_LZMA
#include <LzmaDec.h>
#endif

size_t GetLength(void **p) {
    unsigned char *b = *p;
    *p = b + 2;
    return ((size_t)(b[0]) << 0) |
           ((size_t)(b[1]) << 8);
}

/** Decoder: Zero-terminated string */
const char *GetString(void **p)
{
    size_t len = GetLength(p);
    const char *str = (const char *)*p;
    *p = (char *)(*p) + len;
    return str;
}

/** Decoder: 32 bit unsigned integer */
size_t GetInteger(void **p)
{
    unsigned char *b = *p;
    *p = b + 4;
    return ((size_t)(b[0]) <<  0) |
           ((size_t)(b[1]) <<  8) |
           ((size_t)(b[2]) << 16) |
           ((size_t)(b[3]) << 24);
}

unsigned char GetOpcode(void **p)
{
    unsigned char op = *(unsigned char *)*p;
    *p = (unsigned char *)(*p) + 1;
    return op;
}

BOOL OpCreateDirectory(void **p);
BOOL OpCreateFile(void **p);
BOOL OpSetEnv(void **p);
BOOL OpSetScript(void **p);

typedef BOOL (*POpcodeHandler)(void **);

POpcodeHandler OpcodeHandlers[OP_MAX] =
{
    NULL,
    &OpCreateDirectory,
    &OpCreateFile,
    &OpSetEnv,
    &OpSetScript,
};

// Create a directory (OP_CREATE_DIRECTORY opcode handler)
BOOL OpCreateDirectory(void **p)
{
    const char *dir_name = GetString(p);

    if (dir_name == NULL || *dir_name == '\0') {
        APP_ERROR("dir_name is NULL or empty");
        return FALSE;
    }

    if (!IsPathFreeOfDotElements(dir_name)) {
        APP_ERROR("Directory name contains prohibited relative path elements like '.' or '..'");
        return FALSE;
    }

    char *dir = ExpandInstDirPath(dir_name);
    if (dir == NULL) {
        APP_ERROR("Failed to expand dir_name to installation directory");
        return FALSE;
    }

    DEBUG("Create directory: %s", dir);

    BOOL result = CreateDirectoriesRecursively(dir);

    LocalFree(dir);
    return result;
}

// Create a file (OP_CREATE_FILE opcode handler)
BOOL OpCreateFile(void **p)
{
    const char *file_name = GetString(p);
    size_t file_size = GetInteger(p);
    const void *data = *p;
    *p = (char *)(*p) + file_size;

    if (file_name == NULL || *file_name == '\0') {
        APP_ERROR("file_name is null or empty");
        return FALSE;
    }

    if (!IsPathFreeOfDotElements(file_name)) {
        APP_ERROR("File name contains prohibited relative path elements like '.' or '..'");
        return FALSE;
    }

    char *path = ExpandInstDirPath(file_name);
    if (path == NULL) {
        APP_ERROR("Failed to expand path to installation directory");
        return FALSE;
    }

    DEBUG("Create file: %s", path);

    if (!CreateParentDirectories(path)) {
        APP_ERROR("Failed to create parent directory");
        LocalFree(path);
        return FALSE;
    }

    BOOL result = FALSE;
    HANDLE h = CreateFile(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        DEBUG("Write data(%lu)", file_size);

        DWORD BytesWritten;
        if (WriteFile(h, data, (DWORD)file_size, &BytesWritten, NULL)) {
            if (BytesWritten == (DWORD)file_size) {
                result = TRUE;
            } else {
                APP_ERROR("Write size failure");
            }
        } else {
            APP_ERROR("Write failure (%lu)", GetLastError());
        }
        CloseHandle(h);
    } else {
        APP_ERROR("Failed to create file (%lu)", GetLastError());
    }

    LocalFree(path);
    return result;
}

// Set a environment variable (OP_SETENV opcode handler)
BOOL OpSetEnv(void **p)
{
    const char *name = GetString(p);
    const char *value = GetString(p);

    char *replaced_value = ReplaceInstDirPlaceholder(value);
    if (replaced_value == NULL) {
        APP_ERROR("Failed to replace the value placeholder");
        return FALSE;
    }

    DEBUG("SetEnv(%s, %s)", name, replaced_value);

    BOOL result = SetEnvironmentVariable(name, replaced_value);
    LocalFree(replaced_value);
    if (!result) {
        APP_ERROR("Failed to set environment variable (%lu)", GetLastError());
    }

    return result;
}

// Set a application script info (OP_SET_SCRIPT opcode handler)
BOOL OpSetScript(void **p)
{
    size_t args_size = GetInteger(p);
    const char *args = *p;
    *p = (char *)(*p) + args_size;

    DEBUG("SetScript");

    return InitializeScriptInfo(args, args_size);
}

BOOL ProcessOpcodes(void **p)
{
    unsigned char op;

    for (;;) {
        op = GetOpcode(p);

        if (op >= OP_MAX) {
            APP_ERROR("Opcode out of range: %hhu", op);
            return FALSE;
        }

        if (op == OP_END) {
            DEBUG("Encountered OP_END");
            return TRUE;
        }

        if (OpcodeHandlers[op] == NULL) {
            APP_ERROR("No handler for opcode: %hhu", op);
            return FALSE;
        }

        if (!OpcodeHandlers[op](p)) {
            APP_ERROR("Handler failed for opcode: %hhu", op);
            return FALSE;
        }
    }
}

#if WITH_LZMA
#define LZMA_UNPACKSIZE_SIZE 8
#define LZMA_HEADER_SIZE (LZMA_PROPS_SIZE + LZMA_UNPACKSIZE_SIZE)
#define LZMA_SIZET_MAX ((SizeT)-1)

void *SzAlloc(const ISzAlloc *p, size_t size) { p = p; return LocalAlloc(LMEM_FIXED, size); }
void SzFree(const ISzAlloc *p, void *address) { p = p; LocalFree(address); }
ISzAlloc alloc = { SzAlloc, SzFree };

BOOL DecompressLzma(void *dest, unsigned long long dest_size, const void *src, size_t src_size)
{
    if (dest == NULL) {
        APP_ERROR("Null dest buffer");
        return FALSE;
    }

    if (dest_size > (unsigned long long)LZMA_SIZET_MAX) {
        APP_ERROR("Decompression size exceeds LZMA SizeT limit");
        return FALSE;
    }

    SizeT decompressed_size = (SizeT)dest_size;

    if (src_size < LZMA_HEADER_SIZE) {
        APP_ERROR("Input data too short for LZMA header");
        return FALSE;
    }

    SizeT inSizePure = src_size - LZMA_HEADER_SIZE;
    ELzmaStatus status;

    SRes res = LzmaDecode((Byte *)dest, &decompressed_size, (Byte *)src + LZMA_HEADER_SIZE, &inSizePure,
                          (Byte *)src, LZMA_PROPS_SIZE, LZMA_FINISH_END, &status, &alloc);

    if (res != SZ_OK || status != LZMA_STATUS_FINISHED_WITH_MARK) {
        APP_ERROR("LZMA decompression error: %d, status: %d", res, status);
        return FALSE;
    }

    DEBUG("LZMA decompressed %zu bytes from %zu input bytes", (size_t)decompressed_size, inSizePure);

    return TRUE;
}

BOOL ParseLzmaUnpackSize(const void *data, size_t data_len, unsigned long long *out_size)
{
    if (data == NULL) {
        APP_ERROR("Null data pointer");
        return FALSE;
    }

    if (out_size == NULL) {
        APP_ERROR("Null out_size pointer");
        return FALSE;
    }

    *out_size = 0;

    if (data_len < LZMA_HEADER_SIZE) {
        APP_ERROR("LZMA header is truncated");
        return FALSE;
    }

    const Byte *header = (const Byte *)data + LZMA_PROPS_SIZE;
    unsigned long long size64 = 0;
    for (int i = 0; i < LZMA_UNPACKSIZE_SIZE; i++) {
        size64 |= (unsigned long long)header[i] << (i * 8);
    }

    *out_size = size64;
    DEBUG("Parsed LZMA unpack size: %llu bytes", size64);
    return TRUE;
}
#endif

BOOL ProcessCompressedData(const void *data, size_t data_len)
{
#if WITH_LZMA
    DEBUG("LzmaDecode(%ld)"

    unsigned long long unpack_size = 0;

    if (!ParseLzmaUnpackSize(data, data_len, &unpack_size)) {
        APP_ERROR("Failed to parse LZMA header and extract unpack size");
        return FALSE;
    }

    void *unpack_data = LocalAlloc(LMEM_FIXED, unpack_size);
    if (unpack_data == NULL) {
        APP_ERROR("Memory allocation failed during decompression (%lu)", GetLastError());
        return FALSE;
    }

    if (!DecompressLzma(unpack_data, unpack_size, data, data_len)) {
        APP_ERROR("LZMA decompression failed");
        LocalFree(unpack_data);
        return FALSE;
    }

    void *p = unpack_data;
    BOOL result = ProcessOpcodes(&p);
    LocalFree(unpack_data);

    return result;
#else
    APP_ERROR("Does not support LZMA");
    return FALSE;
#endif
}

BOOL ProcessUncompressedData(const void *data, size_t data_len)
{
    void *p = (void *)data;
    BOOL result = ProcessOpcodes(&p);

    return result;
}

BOOL ProcessImage(const void *data, size_t data_len, BOOL compressed)
{
    if (compressed) {
        DEBUG("Processing compressed data segment with length %zu bytes", data_len);
        return ProcessCompressedData(data, data_len);
    } else {
        DEBUG("Processing uncompressed data segment with length %zu bytes", data_len);
        return ProcessUncompressedData(data, data_len);
    }
}