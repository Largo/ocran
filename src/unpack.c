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
#include "unpack.h"

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
            /* In Phase B, OP_SET_SCRIPT is handled by the Ruby launcher.
               Skip the data if encountered in the bootstrap section. */
            if (!read_integer(reader, &size)) {
                return false;
            }
            if (!read_bytes(reader, size, &bytes)) {
                return false;
            }
            DEBUG("OP_SET_SCRIPT: skipped (%zu bytes)", size);
            return true;
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
    size_t          main_offset;
    size_t          main_size;
};

/*
 * Footer layout (12 bytes before end of packed data):
 *   [main_data_size (4 bytes)] [offset_to_header (4 bytes)] [signature (4 bytes)]
 *
 * Data layout:
 *   [modes (1 byte)] [bootstrap opcodes...] [main data...] [footer]
 */
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

    /* Read the footer: main_data_size and offset_to_header before signature */
    if ((size_t)((const uint8_t *)signature - (const uint8_t *)map_base)
        < sizeof(SizeType) + sizeof(OffsetType)) {
        APP_ERROR("Signature too close to buffer start");

        goto cleanup;
    }

    /* offset_to_header is immediately before signature */
    const void *offset_ptr = (const uint8_t *)signature - sizeof(OffsetType);
    size_t offset = get_offset(offset_ptr);

    /* main_data_size is before offset_to_header */
    const void *main_size_ptr = (const uint8_t *)offset_ptr - sizeof(SizeType);
    size_t main_data_size = get_size(main_size_ptr);

    if (offset > map_size - sizeof(OperationModesType)) {
        APP_ERROR("Offset out of range");

        goto cleanup;
    }
    const void *head = (const uint8_t *)map_base + offset;
    const void *tail = main_size_ptr; /* end of data region (start of footer) */

    /* Verify that the header fits */
    if (head > tail
        || (size_t)((const uint8_t *)tail - (const uint8_t *)head)
           < sizeof(OperationModesType)) {
        APP_ERROR("Not enough space for header before offset");

        goto cleanup;
    }
    context->modes = get_operation_modes(&head);

    /* Calculate bootstrap and main data sizes */
    size_t total_data = (size_t)((const uint8_t *)tail - (const uint8_t *)head);
    if (main_data_size > total_data) {
        APP_ERROR("Main data size exceeds available data");

        goto cleanup;
    }
    size_t bootstrap_size = total_data - main_data_size;

    context->data = head;
    context->data_size = bootstrap_size;
    context->main_offset = (size_t)((const uint8_t *)head - (const uint8_t *)map_base) + bootstrap_size;
    context->main_size = main_data_size;

    DEBUG(
        "OpenPackFile: offset=%zu, modes=%u, bootstrap_size=%zu, main_offset=%zu, main_size=%zu",
        offset, (unsigned)context->modes, context->data_size,
        context->main_offset, context->main_size
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

size_t GetMainDataOffset(const UnpackContext *context)
{
    if (!context) {
        APP_ERROR("context is NULL");
        return 0;
    }
    return context->main_offset;
}

size_t GetMainDataSize(const UnpackContext *context)
{
    if (!context) {
        APP_ERROR("context is NULL");
        return 0;
    }
    return context->main_size;
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

    DEBUG("Bootstrap data segment size: %zu bytes", context->data_size);

    return process_opcodes(context->data, context->data_size);
}
