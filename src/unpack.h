#define OP_END (BYTE)0
#define OP_CREATE_DIRECTORY (BYTE)1
#define OP_CREATE_FILE (BYTE)2
#define OP_SETENV (BYTE)3
#define OP_SET_SCRIPT (BYTE)4
#define OP_MAX (BYTE)5

BOOL MakeDirectory(char *dir_name);
BOOL MakeFile(char *file_name, DWORD file_size, LPVOID data);
BOOL SetEnv(char *name, char *value);
BOOL SetScript(char *app_name, char *script_name, char *cmd_line);

BYTE ProcessOpcodes(LPVOID* p);
