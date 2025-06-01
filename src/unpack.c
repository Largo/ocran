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

bool OpCreateDirectory(void **p);
bool OpCreateFile(void **p);
bool OpSetEnv(void **p);
bool OpSetScript(void **p);

typedef bool (*POpcodeHandler)(void **);

POpcodeHandler OpcodeHandlers[OP_MAX] =
{
    NULL,
    &OpCreateDirectory,
    &OpCreateFile,
    &OpSetEnv,
    &OpSetScript,
};

// Create a directory (OP_CREATE_DIRECTORY opcode handler)
bool OpCreateDirectory(void **p)
{
    const char *dir_name = GetString(p);

    if (dir_name == NULL || *dir_name == '\0') {
        APP_ERROR("dir_name is NULL or empty");
        return false;
    }

    DEBUG("Create directory: %s", dir_name);

    if (!CreateDirectoryUnderInstDir(dir_name)) {
        APP_ERROR("Failed to create directory: %s", dir_name);
        return false;
    }
    return true;
}

// Create a file (OP_CREATE_FILE opcode handler)
bool OpCreateFile(void **p)
{
    const char *file_name = GetString(p);
    size_t file_size = GetInteger(p);
    const void *data = *p;
    *p = (char *)(*p) + file_size;

    if (file_name == NULL || *file_name == '\0') {
        APP_ERROR("file_name is null or empty");
        return false;
    }

    DEBUG("Create file: %s (%zu bytes)", file_name, file_size);

    if (!ExportFileToInstDir(file_name, data, file_size)) {
        APP_ERROR("Failed to export file: %s", file_name);
        return false;
    }
    return true;
}

// Set a environment variable (OP_SETENV opcode handler)
bool OpSetEnv(void **p)
{
    const char *name = GetString(p);
    const char *value = GetString(p);

    char *replaced_value = ReplaceInstDirPlaceholder(value);
    if (replaced_value == NULL) {
        APP_ERROR("Failed to replace the value placeholder");
        return false;
    }

    DEBUG("SetEnv(%s, %s)", name, replaced_value);

    bool result = SetEnvVar(name, replaced_value);
    free(replaced_value);
    if (!result) {
        APP_ERROR("Failed to set environment variable (%lu)", GetLastError());
    }

    return result;
}

// Set a application script info (OP_SET_SCRIPT opcode handler)
bool OpSetScript(void **p)
{
    size_t args_size = GetInteger(p);
    const char *args = *p;
    *p = (char *)(*p) + args_size;

    DEBUG("SetScript");

    return InitializeScriptInfo(args, args_size);
}

bool ProcessOpcodes(void **p)
{
    unsigned char op;

    for (;;) {
        op = GetOpcode(p);

        if (op >= OP_MAX) {
            APP_ERROR("Opcode out of range: %hhu", op);
            return false;
        }

        if (op == OP_END) {
            DEBUG("Encountered OP_END");
            return true;
        }

        if (OpcodeHandlers[op] == NULL) {
            APP_ERROR("No handler for opcode: %hhu", op);
            return false;
        }

        if (!OpcodeHandlers[op](p)) {
            APP_ERROR("Handler failed for opcode: %hhu", op);
            return false;
        }
    }
}

#if WITH_LZMA
#define LZMA_UNPACKSIZE_SIZE 8
#define LZMA_HEADER_SIZE (LZMA_PROPS_SIZE + LZMA_UNPACKSIZE_SIZE)
#define LZMA_SIZET_MAX ((SizeT)-1)

void *SzAlloc(const ISzAlloc *p, size_t size) { p = p; return malloc(size); }
void SzFree(const ISzAlloc *p, void *address) { p = p; free(address); }
ISzAlloc alloc = { SzAlloc, SzFree };

bool DecompressLzma(void *dest, unsigned long long dest_size, const void *src, size_t src_size)
{
    if (dest == NULL) {
        APP_ERROR("Null dest buffer");
        return false;
    }

    if (dest_size > (unsigned long long)LZMA_SIZET_MAX) {
        APP_ERROR("Decompression size exceeds LZMA SizeT limit");
        return false;
    }

    SizeT decompressed_size = (SizeT)dest_size;

    if (src_size < LZMA_HEADER_SIZE) {
        APP_ERROR("Input data too short for LZMA header");
        return false;
    }

    SizeT inSizePure = src_size - LZMA_HEADER_SIZE;
    ELzmaStatus status;

    SRes res = LzmaDecode((Byte *)dest, &decompressed_size, (Byte *)src + LZMA_HEADER_SIZE, &inSizePure,
                          (Byte *)src, LZMA_PROPS_SIZE, LZMA_FINISH_END, &status, &alloc);

    if (res != SZ_OK || status != LZMA_STATUS_FINISHED_WITH_MARK) {
        APP_ERROR("LZMA decompression error: %d, status: %d", res, status);
        return false;
    }

    DEBUG("LZMA decompressed %zu bytes from %zu input bytes", (size_t)decompressed_size, inSizePure);

    return true;
}

bool ParseLzmaUnpackSize(const void *data, size_t data_len, unsigned long long *out_size)
{
    if (data == NULL) {
        APP_ERROR("Null data pointer");
        return false;
    }

    if (out_size == NULL) {
        APP_ERROR("Null out_size pointer");
        return false;
    }

    *out_size = 0;

    if (data_len < LZMA_HEADER_SIZE) {
        APP_ERROR("LZMA header is truncated");
        return false;
    }

    const Byte *header = (const Byte *)data + LZMA_PROPS_SIZE;
    unsigned long long size64 = 0;
    for (int i = 0; i < LZMA_UNPACKSIZE_SIZE; i++) {
        size64 |= (unsigned long long)header[i] << (i * 8);
    }

    *out_size = size64;
    DEBUG("Parsed LZMA unpack size: %llu bytes", size64);
    return true;
}
#endif

bool ProcessCompressedData(const void *data, size_t data_len)
{
#if WITH_LZMA
    DEBUG("LZMA compressed data segment size: %zu bytes", data_len);

    unsigned long long unpack_size = 0;

    if (!ParseLzmaUnpackSize(data, data_len, &unpack_size)) {
        APP_ERROR("Failed to parse LZMA header and extract unpack size");
        return false;
    }

    if (unpack_size > (unsigned long long)SIZE_MAX) {
        APP_ERROR("Size too large to fit in size_t");
        return false;
    }

    void *unpack_data = malloc(unpack_size);
    if (!unpack_data) {
        APP_ERROR("Memory allocation failed during decompression");
        return false;
    }

    if (!DecompressLzma(unpack_data, unpack_size, data, data_len)) {
        APP_ERROR("LZMA decompression failed");
        free(unpack_data);
        return false;
    }

    void *p = unpack_data;
    bool result = ProcessOpcodes(&p);
    free(unpack_data);

    return result;
#else
    APP_ERROR("Does not support LZMA");
    return false;
#endif
}

bool ProcessUncompressedData(const void *data, size_t data_len)
{
    DEBUG("Uncompressed data segment size: %zu bytes", data_len);

    void *p = (void *)data;
    bool result = ProcessOpcodes(&p);

    return result;
}

bool ProcessImage(const void *data, size_t data_len, bool compressed)
{
    if (compressed) {
        return ProcessCompressedData(data, data_len);
    } else {
        return ProcessUncompressedData(data, data_len);
    }
}