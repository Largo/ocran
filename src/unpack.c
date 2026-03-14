#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#endif
#include "error.h"
#include "system_utils.h"
#include "inst_dir.h"
#include "script_info.h"
#include "unpack.h"

#if WITH_LZMA
#include <LzmaDec.h>
#endif

typedef uint32_t SizeType;

static inline size_t get_size(const void *p)
{
    const uint8_t *b = p;
    return  (size_t)b[0]
         | ((size_t)b[1] <<  8)
         | ((size_t)b[2] << 16)
         | ((size_t)b[3] << 24);
}

typedef struct {
    const uint8_t *begin;
    const uint8_t *end;
    const uint8_t *cur;
} UnpackReader;

static bool read_bytes(UnpackReader *reader, size_t size, const uint8_t **ptr)
{
    size_t avail = (size_t)(reader->end - reader->cur);
    if (size > avail) {
        DEBUG("failed to read requested data bytes");
        return false;
    }

    *ptr = reader->cur;
    reader->cur += size;
    return true;
}

static bool read_integer(UnpackReader *reader, size_t *size);

static bool read_string(UnpackReader *reader, const char **str)
{
    size_t len;
    if (!read_integer(reader, &len)) {
        DEBUG("failed to read string size");
        return false;
    }

    if (len == 0) {
        DEBUG("string size is zero");
        return false;
    }

    const uint8_t *bytes;
    if (!read_bytes(reader, len, &bytes)) {
        DEBUG("failed to read string data");
        return false;
    }

    if (bytes[len - 1] != '\0') {
        DEBUG("string is not null-terminated");
        return false;
    }

    *str = (const char *)bytes;
    return true;
}

static bool read_integer(UnpackReader *reader, size_t *size)
{
    const uint8_t *b;
    if (!read_bytes(reader, sizeof(SizeType), &b)) {
        DEBUG("failed to read integer value");
        return false;
    }
    
    *size = get_size(b);
    return true;
}

static bool read_opcode(UnpackReader *reader, Opcode *opcode)
{
    const uint8_t *b;
    if (!read_bytes(reader, 1, &b)) {
        DEBUG("failed to read opcode");
        return false;
    }

    *opcode = (Opcode)b[0];
    return true;
}

static bool process_opcode(UnpackReader *reader, Opcode opcode)
{
    const char *name, *value;
    const uint8_t *bytes;
    size_t size;

    switch (opcode) {
        case OP_CREATE_DIRECTORY: {
            if (!read_string(reader, &name)) {
                return false;
            }
            DEBUG("OP_CREATE_DIRECTORY: path='%s'", name);
            return CreateDirectoryUnderInstDir(name);
        }

        case OP_CREATE_FILE: {
            if (!read_string(reader, &name)) {
                return false;
            }
            if (!read_integer(reader, &size)) {
                return false;
            }
            if (!read_bytes(reader, size, &bytes)) {
                return false;
            }
            const void *data = bytes;
            DEBUG("OP_CREATE_FILE: path='%s' (%zu bytes)", name, size);
            return ExportFileToInstDir(name, data, size);
        }

        case OP_SETENV: {
            if (!read_string(reader, &name)) {
                return false;
            }
            if (!read_string(reader, &value)) {
                return false;
            }
            DEBUG("OP_SETENV: name='%s', value='%s'", name, value);
            return SetEnvWithInstDir(name, value);
        }

        case OP_SET_SCRIPT: {
            if (!read_integer(reader, &size)) {
                return false;
            }
            if (!read_bytes(reader, size, &bytes)) {
                return false;
            }
            const char *args = (const char *)bytes;
            DEBUG("OP_SET_SCRIPT");
            return SetScriptInfo(args, size);
        }

        case OP_CREATE_SYMLINK: {
            if (!read_string(reader, &name)) {
                return false;
            }
            if (!read_string(reader, &value)) {
                return false;
            }
            DEBUG("OP_CREATE_SYMLINK: link='%s', target='%s'", name, value);
#ifndef _WIN32
            return CreateSymlinkUnderInstDir(name, value);
#else
            DEBUG("OP_CREATE_SYMLINK: skipped on Windows");
            return true;
#endif
        }

        default: {
            DEBUG("Invalid opcode: %d", opcode);
            return false;
        }
    }

    /* Unreachable: every case returns earlier */
    return false;
}

static bool process_opcodes(const void *data, size_t data_size)
{
    UnpackReader reader = {
        .begin = (const uint8_t *)data,
        .cur   = (const uint8_t *)data,
        .end   = (const uint8_t *)data + data_size
    };
    Opcode opcode;

    while (reader.cur < reader.end) {
        if (!read_opcode(&reader, &opcode)) {
            return false;
        }
        if (!process_opcode(&reader, opcode)) {
            return false;
        }
    }
    return true;
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
    return true;
}

static unsigned long long parse_lzma_unpack_size(const void *data)
{
    const Byte *size_bytes = (const Byte *)data + LZMA_PROPS_SIZE;
    unsigned long long size64 = 0;
    for (int i = 0; i < LZMA_UNPACKSIZE_SIZE; i++) {
        size64 |= (unsigned long long)size_bytes[i] << (i * 8);
    }
    return size64;
}
#endif

static void *DecompressLzmaData(const void *data, size_t data_size,
                                size_t *decompressed_size)
{
#if WITH_LZMA
    if (data_size < LZMA_HEADER_SIZE) {
        APP_ERROR("LZMA header is truncated");
        return NULL;
    }

    unsigned long long unpack_size = parse_lzma_unpack_size(data);

    DEBUG("Parsed LZMA decompressed size: %llu bytes", unpack_size);

    if (unpack_size > (unsigned long long)LZMA_SIZET_MAX) {
        APP_ERROR("Decompression size exceeds LZMA SizeT limit");
        return NULL;
    }

    if (unpack_size > (unsigned long long)SIZE_MAX) {
        APP_ERROR("Size too large to fit in size_t");
        return NULL;
    }

    void *unpack_data = malloc(unpack_size);
    if (!unpack_data) {
        APP_ERROR("Memory allocation failed during decompression");
        return NULL;
    }

    if (!decompress_lzma(unpack_data, unpack_size, data, data_size)) {
        APP_ERROR("LZMA decompression failed");
        free(unpack_data);
        return NULL;
    }

    *decompressed_size = unpack_size;
    return unpack_data;
#else
    APP_ERROR("Does not support LZMA");
    return NULL;
#endif
}

const uint8_t Signature[] = { 0x41, 0xb6, 0xba, 0x4e };

/** Manages digital signatures **/

/* see https://en.wikipedia.org/wiki/Portable_Executable for explanation of these header fields */
#define SECURITY_ENTRY(header) ((header)->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_SECURITY])

#ifdef _WIN32
/* The NTHeader is another name for the PE header. It is the 'modern' executable header
   as opposed to the DOS_HEADER which exists for legacy reasons */
static PIMAGE_NT_HEADERS retrieveNTHeader(const void *ptr) {
  PIMAGE_DOS_HEADER dosHeader = (PIMAGE_DOS_HEADER)ptr;

  /* e_lfanew is an RVA (relative virtual address, i.e offset) to the NTHeader
   to get a usable pointer we add the RVA to the base address */
  return (PIMAGE_NT_HEADERS)((DWORD_PTR)dosHeader + (DWORD)dosHeader->e_lfanew);
}

/* Check whether there's an embedded digital signature */
static bool isDigitallySigned(const void *ptr, size_t buffer_size) {
  PIMAGE_NT_HEADERS ntHeader = retrieveNTHeader(ptr);
  DWORD securityAddr = SECURITY_ENTRY(ntHeader).VirtualAddress;
  DWORD securitySize = SECURITY_ENTRY(ntHeader).Size;

  /* A valid digital signature must have non-zero size and the address must be within the file bounds */
  if (securitySize == 0) {
    return false;
  }

  /* Check if the security entry points to a valid location within the file */
  if (securityAddr == 0 || securityAddr >= buffer_size) {
    return false;
  }

  /* Check if the entire security entry fits within the file */
  if (securityAddr + securitySize > buffer_size) {
    return false;
  }

  return true;
}
#endif

static const void *find_signature(const void *buffer, size_t buffer_size)
{
#ifdef _WIN32
    // Check if the executable is digitally signed
    if (!isDigitallySigned(buffer, buffer_size)) {
        // No digital signature, use the original logic
        const void *sig = (const uint8_t *)buffer + buffer_size - sizeof(Signature);
        if (memcmp(sig, Signature, sizeof(Signature))) {
            return NULL;
        }
        return sig;
    }
    else {
        // Executable is digitally signed
        PIMAGE_NT_HEADERS ntHeader = retrieveNTHeader(buffer);
        DWORD securityAddr = SECURITY_ENTRY(ntHeader).VirtualAddress;

        if (securityAddr == 0 || securityAddr > buffer_size) {
            DEBUG("Invalid security address: %lu", (unsigned long)securityAddr);
            return NULL;
        }

        DWORD offset = securityAddr - 1;
        const char *searchPtr = (const char *)buffer;

        /* There is unfortunately a 'buffer' of null bytes between the
           ocraSignature and the digital signature. This buffer appears to be random
           in size, so the only way we can account for it is to search backwards
           for the first non-null byte.
           NOTE: this means that the hard-coded Ocra signature cannot end with a null byte.
        */
        while(offset > sizeof(Signature) && !searchPtr[offset])
            offset--;

        /* -3 because we're already at the first byte and we need to go back 4 bytes */
        if (offset < sizeof(Signature)) {
            DEBUG("Signature search went out of bounds");
            return NULL;
        }

        const void *sig = (const void *)&searchPtr[offset - 3];

        if (memcmp(sig, Signature, sizeof(Signature))) {
            DEBUG("Signature mismatch in signed executable");
            return NULL;
        }
        return sig;
    }
#else
    // POSIX: no PE headers, just check the end of the file
    if (buffer_size < sizeof(Signature)) {
        return NULL;
    }

    const void *sig = (const uint8_t *)buffer + buffer_size - sizeof(Signature);
    if (memcmp(sig, Signature, sizeof(Signature)) != 0) {
        return NULL;
    }

    return sig;
#endif
}

typedef uint8_t OperationModesType;

OperationModes get_operation_modes(const void **p)
{
    const OperationModesType *q = (const OperationModesType *)*p;
    *p = q + 1;
    return (OperationModes)*q;
}

typedef SizeType OffsetType;

size_t get_offset(const void *p)
{
    return get_size(p);
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
    tail = (const uint8_t *)tail - sizeof(OffsetType);
    size_t offset = get_offset(tail);
    if (offset > map_size - sizeof(OperationModesType)) {
        APP_ERROR("Offset out of range");
        
        goto cleanup;
    }
    const void *head = (const uint8_t *)map_base + offset;

    /* Verify that the header fits immediately before the offset */
    if (head > tail
        || (size_t)((const uint8_t *)tail - (const uint8_t *)head)
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

    DEBUG("Data segment size: %zu bytes", context->data_size);

    bool compressed = IsDataCompressed(context->modes);
    void  *data;
    size_t data_size;

    if (compressed) {
        data = DecompressLzmaData(
            context->data,
            context->data_size,
            &data_size
        );
        if (!data) {
            APP_ERROR("LZMA decompression failed");
            return false;
        }
        DEBUG("LZMA decompressed %zu bytes", data_size);
    } else {
        data      = (void *)context->data;
        data_size = context->data_size;
    }

    bool ok = process_opcodes(data, data_size);

    if (compressed) {
        free(data);
    }
    return ok;
}
