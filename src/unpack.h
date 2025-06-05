#include <stdbool.h>

typedef enum {
    OP_END              = 0,
    OP_CREATE_DIRECTORY = 1,
    OP_CREATE_FILE      = 2,
    OP_SETENV           = 3,
    OP_SET_SCRIPT       = 4,
} Opcode;

bool ProcessImage(const void *data, size_t data_len, bool compressed);
const void *FindSignature(const void *buffer, size_t size);
