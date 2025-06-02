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

static bool vformat_message(char *buffer, size_t buffer_size, const char *label,
                            const char* format, va_list args)
{
    if (!buffer || buffer_size < 2) {
        return false;
    }

    size_t offset = 0;

    if (label) {
        int label_needed = snprintf(buffer, buffer_size, "%s: ", label);
        if (label_needed < 0 || (size_t)label_needed >= buffer_size) {
            return false;
        }
        offset = (size_t)label_needed;
    }

    int needed = vsnprintf(buffer + offset, buffer_size - offset, format, args);
    if (needed < 0) {
        return false;
    } else if ((size_t)needed >= buffer_size - offset - 2) {
        offset = buffer_size - 2;
    } else {
        offset += (size_t)needed;
    }
    buffer[offset++] = '\n';
    buffer[offset]   = '\0';
    return true;
}

static void print_message(const char *label, const char *format, va_list args)
{
    char text[4096];
    if (vformat_message(text, sizeof(text), label, format, args)) {
        fputs(text, stderr);
    } else {
        fputs("log message formatting failed\n", stderr);
    }
}

// Prints a fatal error message to stderr.
void PrintFatalMessage(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    print_message("FATAL", format, args);
    va_end(args);
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

    va_list args;
    va_start(args, format);
    print_message("ERROR", format, args);
    va_end(args);
}

// Prints a debug message to stderr if in debug mode.
void PrintDebugMessage(const char *format, ...)
{
    if (!debug_mode) return;

    va_list args;
    va_start(args, format);
    print_message("DEBUG", format, args);
    va_end(args);
}
