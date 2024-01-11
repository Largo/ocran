#define OP_END (BYTE)0
#define OP_CREATE_DIRECTORY (BYTE)1
#define OP_CREATE_FILE (BYTE)2
#define OP_SETENV (BYTE)3
#define OP_SET_SCRIPT (BYTE)4
#define OP_MAX (BYTE)5

BOOL MakeDirectory(LPTSTR dir_name);
BOOL MakeFile(LPTSTR file_name, DWORD file_size, LPVOID data);
BOOL SetEnv(LPTSTR name, LPTSTR value);
BOOL SetScript(LPTSTR app_name, LPTSTR cmd_line);

BYTE ProcessOpcodes(LPVOID* p);
