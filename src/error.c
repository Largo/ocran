#include <windows.h>
#include <string.h>
#include <stdio.h>
#include "error.h"

DWORD PrintFatalMessage(char *format, ...)
{
    fprintf_s(stderr, "FATAL: ");
    va_list args;
    va_start(args, format);
    vfprintf_s(stderr, format, args);
    va_end(args);
    fprintf_s(stderr, "\n");
    return EXIT_CODE_FAILURE;
}

DWORD PrintFatalMessageBox(char *format, ...)
{
    char TextBuffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(TextBuffer, 1024, format, args);
    va_end(args);
    MessageBox(NULL, TextBuffer, "OCRAN", MB_OK | MB_ICONWARNING);
    return EXIT_CODE_FAILURE;
}

DWORD PrintLastError(char *msg) {
    DWORD err = GetLastError();
    fprintf_s(stderr, "ERROR: %s (%lu)\n", msg, err);
    return err;
}

void PrintDebugMessage(char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf_s(stderr, format, args);
    va_end(args);
    fprintf_s(stderr, "\n");
}
