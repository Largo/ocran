#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "error.h"
#include "filesystem_utils.h"
#include "inst_dir.h"
#include "script_info.h"
#include "unpack.h"

#if WITH_LZMA
#include <LzmaDec.h>
#endif

static const void *get_data(const void **p, size_t size)
{
    const void *data = *p;
    *p = (uint8_t *)(*p) + size;
    return data;
}

static size_t get_length(const void **p)
{
    const uint8_t *b = get_data(p, 2);
    return (size_t)b[0] | ((size_t)b[1] << 8);
}

static const char *get_string(const void **p)
{
    size_t len = get_length(p);
    return (const char *)get_data(p, len);
}

static size_t get_integer(const void **p)
{
    const uint8_t *b = get_data(p, 4);
    uint32_t v = (uint32_t)b[0]
               | ((uint32_t)b[1] <<  8)
               | ((uint32_t)b[2] << 16)
               | ((uint32_t)b[3] << 24);
    return (size_t)v;
}

static Opcode get_opcode(const void **p)
{
    const uint8_t *b = get_data(p, 1);
    return (Opcode)b[0];
}

static bool process_opcodes(const void *p)
{
    Opcode op;

    for (;;) {
        op = get_opcode(&p);

        switch (op) {
            case OP_END:
                DEBUG("Encountered OP_END");
                return true;
                break;

            case OP_CREATE_DIRECTORY:
                const char *dir_name = get_string(&p);
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
                const char *file_name = get_string(&p);
                size_t file_size = get_integer(&p);
                const void *data = get_data(&p, file_size);
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
                const char *name  = get_string(&p);
                const char *value = get_string(&p);
                DEBUG("OP_SETENV: %s, %s", name, value);
                if (!SetEnvWithInstDir(name, value)) {
                    return false;
                }
                break;

            case OP_SET_SCRIPT:            
                size_t args_size = get_integer(&p);
                const char *args = get_data(&p, args_size);
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

static bool decompress_lzma(void *dest, unsigned long long dest_size,
                            const void *src, size_t src_size)
{
    SizeT decompressed_size = (SizeT)dest_size;
    SizeT inSizePure = src_size - LZMA_HEADER_SIZE;
    ELzmaStatus status;

    SRes res = LzmaDecode((Byte *)dest, &decompressed_size,
                          (Byte *)src + LZMA_HEADER_SIZE, &inSizePure,
                          (Byte *)src, LZMA_PROPS_SIZE,
                          LZMA_FINISH_END, &status, &alloc);

    if (res != SZ_OK || status != LZMA_STATUS_FINISHED_WITH_MARK) {
        APP_ERROR("LZMA decompression error: %d, status: %d", res, status);
        return false;
    }

    DEBUG(
        "LZMA decompressed %zu bytes from %zu input bytes",
        (size_t)decompressed_size, inSizePure
    );

    return true;
}

static unsigned long long parse_lzma_unpack_size(const void *data)
{
    const Byte *header = (const Byte *)data + LZMA_PROPS_SIZE;
    unsigned long long size64 = 0;
    for (int i = 0; i < LZMA_UNPACKSIZE_SIZE; i++) {
        size64 |= (unsigned long long)header[i] << (i * 8);
    }
    return size64;
}
#endif

bool ProcessCompressedData(const void *data, size_t data_len)
{
#if WITH_LZMA
    DEBUG("LZMA compressed data segment size: %zu bytes", data_len);

    if (data_len < LZMA_HEADER_SIZE) {
        APP_ERROR("LZMA header is truncated");
        return false;
    }

    unsigned long long unpack_size = parse_lzma_unpack_size(data);

    DEBUG("Parsed LZMA unpack size: %llu bytes", unpack_size);

    if (unpack_size > (unsigned long long)LZMA_SIZET_MAX) {
        APP_ERROR("Decompression size exceeds LZMA SizeT limit");
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

    if (!decompress_lzma(unpack_data, unpack_size, data, data_len)) {
        APP_ERROR("LZMA decompression failed");
        free(unpack_data);
        return false;
    }

    bool result = process_opcodes(unpack_data);
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

    bool result = process_opcodes(data);

    return result;
}

const uint8_t Signature[] = { 0x41, 0xb6, 0xba, 0x4e };

static const void *find_signature(const void *buffer, size_t buffer_size)
{
    // Currently, the signature is being searched for at the end of the file.
    const void *sig = (const uint8_t *)buffer + buffer_size - sizeof(Signature);
    if (memcmp(sig, Signature, sizeof(Signature))) {
        return NULL;
    }
    return sig;
}

typedef uint8_t OperationModesType;

OperationModes get_operation_modes(const void **p)
{
    const OperationModesType *q = (const OperationModesType *)*p;
    *p = q + 1;
    return (OperationModes)*q;
}

typedef uint32_t OffsetType;

size_t get_offset(const void **p)
{
    const OffsetType *q = (const OffsetType *)*p - 1;
    *p = q;
    return (size_t)*q;
}

struct UnpackContext {
    MemoryMap      *map;
    OperationModes  modes;
    const void     *data;
    size_t          data_size;
};

UnpackContext *OpenPackFile(const char *self_path)
{
    UnpackContext *context = NULL;

    if (!self_path || !*self_path) {
        APP_ERROR("self_path is NULL or empty");

        goto cleanup;
    }

    context = calloc(1, sizeof(UnpackContext)) ;
    if (!context) {
        APP_ERROR("Memory allocation failed for context");

        goto cleanup;
    }

    context->map = CreateMemoryMap(self_path);
    if (!context->map) {
        APP_ERROR("Failed to map the executable file");

        goto cleanup;
    }
    const void *map_base = GetMemoryMapBase(context->map);
    size_t      map_size = GetMemoryMapSize(context->map);

     /* Locate the end of the packed data */
    if (map_size < sizeof(Signature)) {
        APP_ERROR("Too small to contain signature");

        goto cleanup;
    }
    const void *signature = find_signature(map_base, map_size);
    if (!signature) {
        APP_ERROR("Signature not found");

        goto cleanup;
    }
    if ((size_t)((const uint8_t *)signature - (const uint8_t *)map_base)
        < sizeof(OffsetType)) {
        APP_ERROR("Signature too close to buffer start");

        goto cleanup;
    }
    const void *tail = signature;

    /* Determine the start of the packed data */
    size_t offset = get_offset(&tail);
    if (offset > map_size - sizeof(OperationModesType)) {
        APP_ERROR("Offset out of range");
        
        goto cleanup;
    }
    const void *head = (const uint8_t *)map_base + offset;

    /* Verify that the header fits immediately before the offset */
    if ((size_t)((const uint8_t *)tail - (const uint8_t *)head)
        < sizeof(OperationModesType)) {
        APP_ERROR("Not enough space for header before offset");
        
        goto cleanup;
    }
    context->modes = get_operation_modes(&head);
    context->data = head;
    context->data_size = (const uint8_t *)tail - (const uint8_t *)head;

    DEBUG(
        "OpenPackFile: offset=%zu, modes= %u, data_size=%zu",
        offset, (unsigned)context->modes, context->data_size
    );
    return context;

cleanup:
    if (context) {
        ClosePackFile(context);
    }
    return NULL;
}

bool ClosePackFile(UnpackContext *context)
{
    if (context) {
        if (context->map) {
            DestroyMemoryMap(context->map);
        }
        free(context);
    }
    return true;
}

OperationModes GetOperationModes(const UnpackContext *context)
{
    if (!context) {
        APP_ERROR("context is NULL");

        return 0;
    }
    return context->modes;
}

static inline bool IsMode(OperationModes modes, OperationModes mask) {
    return (modes & mask) == mask;
}

bool IsDebugMode(OperationModes modes) {
    return IsMode(modes, DEBUG_MODE);
}

bool IsExtractToExeDir(OperationModes modes) {
    return IsMode(modes, EXTRACT_TO_EXE_DIR);
}

bool IsAutoCleanInstDir(OperationModes modes) {
    return IsMode(modes, AUTO_CLEAN_INST_DIR);
}

bool IsChdirBeforeScript(OperationModes modes) {
    return IsMode(modes, CHDIR_BEFORE_SCRIPT);
}

bool IsDataCompressed(OperationModes modes) {
    return IsMode(modes, DATA_COMPRESSED);
}

bool ProcessImage(const UnpackContext *context)
{
    if (!context) {
        APP_ERROR("context is NULL");

        return false;
    }

    if (IsDataCompressed(context->modes)) {
        return ProcessCompressedData(context->data, context->data_size);
    } else {
        return ProcessUncompressedData(context->data, context->data_size);
    }
}
