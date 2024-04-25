#include <windows.h>
#include <string.h>
#include <stdio.h>
#include "error.h"

BOOL DebugModeEnabled = FALSE;

// Initialize debug mode
BOOL InitializeDebugMode()
{
    if (DebugModeEnabled) return TRUE;

    DebugModeEnabled = TRUE;

    return DebugModeEnabled;
}

// Prints a fatal error message to stderr.
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

// Displays a fatal error message via a message box.
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

// Prints the last error message to stderr if in debug mode.
DWORD PrintLastErrorMessage(char *format, ...)
{
    DWORD err = GetLastError();

    if (!DebugModeEnabled) return err;

    fprintf_s(stderr, "ERROR: ");
    va_list args;
    va_start(args, format);
    vfprintf_s(stderr, format, args);
    va_end(args);
    fprintf_s(stderr, " (%lu)", err);
    fprintf_s(stderr, "\n");

    return err;
}

// Prints an application level error message to stderr if in debug mode.
DWORD PrintAppErrorMessage(char *format, ...)
{
    if (!DebugModeEnabled) return EXIT_CODE_FAILURE;

    fprintf_s(stderr, "ERROR: ");
    va_list args;
    va_start(args, format);
    vfprintf_s(stderr, format, args);
    va_end(args);
    fprintf_s(stderr, "\n");

    return EXIT_CODE_FAILURE;
}

// Prints a debug message to stderr if in debug mode.
void PrintDebugMessage(char *format, ...)
{
    if (!DebugModeEnabled) return;

    fprintf_s(stderr, "DEBUG: ");
    va_list args;
    va_start(args, format);
    vfprintf_s(stderr, format, args);
    va_end(args);
    fprintf_s(stderr, "\n");
}
