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

bool ProcessOpcodes(void **p)
{
    Opcode op;

    for (;;) {
        op = (Opcode)GetOpcode(p);

        switch (op) {
            case OP_END:
                DEBUG("Encountered OP_END");
                return true;
                break;

            case OP_CREATE_DIRECTORY:
                const char *dir_name = GetString(p);
                if (!dir_name || !*dir_name) {
                    APP_ERROR("dir_name is NULL or empty");
                    return false;
                }
                DEBUG("OP_CREATE_DIRECTORY: %s", dir_name);
                if (!CreateDirectoryUnderInstDir(dir_name)) {
                    return false;
                }
                break;

            case OP_CREATE_FILE:
                const char *file_name = GetString(p);
                size_t file_size = GetInteger(p);
                const void *data = *p;
                *p = (char *)(*p) + file_size;
                if (!file_name || !*file_name) {
                    APP_ERROR("file_name is NULL or empty");
                    return false;
                }
                DEBUG("OP_CREATE_FILE: %s (%zu bytes)", file_name, file_size);
                if (!ExportFileToInstDir(file_name, data, file_size)) {
                    return false;
                }
                break;

            case OP_SETENV:
                const char *name  = GetString(p);
                const char *value = GetString(p);
                DEBUG("OP_SETENV: %s, %s", name, value);
                if (!SetEnvWithInstDir(name, value)) {
                    return false;
                }
                break;

            case OP_SET_SCRIPT:            
                size_t args_size = GetInteger(p);
                const char *args = *p;
                *p = (char *)(*p) + args_size;
                DEBUG("OP_SET_SCRIPT");
                if (!InitializeScriptInfo(args, args_size)) {
                    return false;
                }
                break;

            default:
                APP_ERROR("No handler for opcode: %d", op);
                return false;
                break;
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