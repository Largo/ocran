#include <windows.h>
#include <string.h>
#include "unpack.h"

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

BOOL OpCreateDirectory(void **p)
{
    const char *dir_name = GetString(p);

    return MakeDirectory(dir_name);
}

BOOL OpCreateFile(void **p)
{
    const char *file_name = GetString(p);
    size_t file_size = GetInteger(p);
    const void *data = *p;
    *p = (char *)(*p) + file_size;

    return MakeFile(file_name, file_size, data);
}

BOOL OpSetEnv(void **p)
{
    const char *name = GetString(p);
    const char *value = GetString(p);

    return SetEnv(name, value);
}

BOOL OpSetScript(void **p)
{
    size_t args_size = GetInteger(p);
    const char *args = *p;
    *p = (char *)(*p) + args_size;

    return SetScript(args, args_size);
}

unsigned char ProcessOpcodes(void **p)
{
    unsigned char op;

    do {
        op = GetOpcode(p);

        if (op == OP_END || op >= OP_MAX || !OpcodeHandlers[op]) break;

    } while (OpcodeHandlers[op](p));

    return op;
}
