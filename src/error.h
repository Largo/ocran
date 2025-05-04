// Exit code definitions
#define EXIT_CODE_SUCCESS ((DWORD)0)
#define EXIT_CODE_FAILURE ((DWORD)-1)

/**
 * EnableDebugMode - Enable debug mode
 *
 * This function enables debug mode and attaches a console for debug output.
 */
void EnableDebugMode();

/**
 * PrintFatalMessage - Prints a fatal error message to stderr.
 *
 * This function prints a formatted error message to stderr. The message is
 * prefixed with "FATAL: ".
 *
 * @param format The format of the error message to be displayed. This is a printf-like
 * format string followed by additional arguments.
 */
void PrintFatalMessage(char *format, ...);

/**
 * PrintFatalMessageBox - Displays a fatal error message via a message box.
 *
 * This function displays a formatted error message in a message box with the
 * caption 'OCRAN' and an icon of MB_ICONWARNING.
 *
 * @param format The format of the error message to be displayed. This is a printf-like
 * format string followed by additional arguments.
 */
void PrintFatalMessageBox(char *format, ...);

#ifdef _CONSOLE
#define FATAL(...) PrintFatalMessage(__VA_ARGS__)
#else
#define FATAL(...) PrintFatalMessageBox(__VA_ARGS__)
#endif

/**
 * PrintLastErrorMessage - Prints the last error message to stderr if in debug mode.
 *
 * This function prints a formatted error message and the last error code to stderr.
 * The error message starts with "ERROR: ", followed by the result of GetLastError function.
 *
 * @param format The format of the error message to be displayed. This is a printf-like
 * format string followed by additional arguments.
 */
void PrintLastErrorMessage(char *format, ...);
#define LAST_ERROR(...) PrintLastErrorMessage(__VA_ARGS__)

/**
 * PrintAppErrorMessage - Prints an application level error message to stderr if in debug mode.
 *
 * This function prints a formatted error message to stderr. The message is
 * prefixed with "ERROR: ".
 *
 * @param format The format of the error message to be displayed. This is a printf-like
 * format string followed by additional arguments.
 */
void PrintAppErrorMessage(char *format, ...);
#define APP_ERROR(...) PrintAppErrorMessage(__VA_ARGS__)

/**
 * PrintDebugMessage - Prints a debug message to stderr if in debug mode.
 *
 * This function prints a formatted debug message to stderr. The message is
 * prefixed with "DEBUG: ".
 *
 * @param format The format of the debug message to be displayed. This is a printf-like
 * format string followed by additional arguments.
 */
void PrintDebugMessage(char *format, ...);
#define DEBUG(...) PrintDebugMessage(__VA_ARGS__)
