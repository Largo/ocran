#include <windows.h>
#include <string.h>
#include "unpack.h"

/** Decoder: Zero-terminated string */
char *GetString(LPVOID* p)
{
    SIZE_T len = (SIZE_T)*(LPWORD)*p;
    *p += sizeof(WORD);
    char *str = *p;
    *p += len;
    return str;
}

/** Decoder: 32 bit unsigned integer */
DWORD GetInteger(LPVOID* p)
{
    DWORD dw = *(DWORD*)*p;
    *p += sizeof(DWORD);
    return dw;
}

BYTE GetOpcode(LPVOID* p)
{
    BYTE op = *(LPBYTE)*p;
    *p += sizeof(BYTE);
    return op;
}

BOOL OpCreateDirectory(LPVOID* p);
BOOL OpCreateFile(LPVOID* p);
BOOL OpSetEnv(LPVOID* p);
BOOL OpSetScript(LPVOID* p);

typedef BOOL (*POpcodeHandler)(LPVOID*);

POpcodeHandler OpcodeHandlers[OP_MAX] =
{
    NULL,
    &OpCreateDirectory,
    &OpCreateFile,
    &OpSetEnv,
    &OpSetScript,
};

BOOL OpCreateDirectory(LPVOID* p)
{
    LPTSTR dir_name = GetString(p);

    return MakeDirectory(dir_name);
}

BOOL OpCreateFile(LPVOID* p)
{
    char *file_name = GetString(p);
    DWORD file_size = GetInteger(p);
    LPVOID data = *p;
    *p += file_size;

    return MakeFile(file_name, file_size, data);
}

BOOL OpSetEnv(LPVOID* p)
{
    char *name = GetString(p);
    char *value = GetString(p);

    return SetEnv(name, value);
}

BOOL OpSetScript(LPVOID* p)
{
    char *app_name = GetString(p);
    char *cmd_line = GetString(p);

    return SetScript(app_name, cmd_line);
}

BYTE ProcessOpcodes(LPVOID* p)
{
    BYTE op;

    do {
        op = GetOpcode(p);

        if (op == OP_END || op >= OP_MAX || !OpcodeHandlers[op]) break;

    } while (OpcodeHandlers[op](p));

    return op;
}
