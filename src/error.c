#include <windows.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdbool.h>
#include "error.h"

static bool debug_mode = false;

// Enable debug mode
void EnableDebugMode()
{
    debug_mode = true;
}

// Prints a fatal error message to stderr.
void PrintFatalMessage(const char *format, ...)
{
    fprintf_s(stderr, "FATAL: ");
    va_list args;
    va_start(args, format);
    vfprintf_s(stderr, format, args);
    va_end(args);
    fprintf_s(stderr, "\n");
}

// Displays a fatal error message via a message box.
void PrintFatalMessageBox(const char *format, ...)
{
    char TextBuffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(TextBuffer, 1024, format, args);
    va_end(args);
    MessageBox(NULL, TextBuffer, "OCRAN", MB_OK | MB_ICONWARNING);
}

// Prints an application level error message to stderr if in debug mode.
void PrintAppErrorMessage(const char *format, ...)
{
    if (!debug_mode) return;

    fprintf_s(stderr, "ERROR: ");
    va_list args;
    va_start(args, format);
    vfprintf_s(stderr, format, args);
    va_end(args);
    fprintf_s(stderr, "\n");
}

// Prints a debug message to stderr if in debug mode.
void PrintDebugMessage(const char *format, ...)
{
    if (!debug_mode) return;

    fprintf_s(stderr, "DEBUG: ");
    va_list args;
    va_start(args, format);
    vfprintf_s(stderr, format, args);
    va_end(args);
    fprintf_s(stderr, "\n");
}
