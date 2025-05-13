#include <stdbool.h>

#define OP_END (BYTE)0
#define OP_CREATE_DIRECTORY (BYTE)1
#define OP_CREATE_FILE (BYTE)2
#define OP_SETENV (BYTE)3
#define OP_SET_SCRIPT (BYTE)4
#define OP_MAX (BYTE)5

bool ProcessImage(const void *data, size_t data_len, bool compressed);
