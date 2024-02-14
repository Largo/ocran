#define OP_END (BYTE)0
#define OP_CREATE_DIRECTORY (BYTE)1
#define OP_CREATE_FILE (BYTE)2
#define OP_SETENV (BYTE)3
#define OP_SET_SCRIPT (BYTE)4
#define OP_MAX (BYTE)5

BOOL MakeDirectory(const char *dir_name);
BOOL MakeFile(const char *file_name, DWORD file_size, const void *data);
BOOL SetEnv(const char *name, const char *value);
BOOL SetScript(const char *app_name, const char *script_name, const char *cmd_line);

BYTE ProcessOpcodes(LPVOID* p);
