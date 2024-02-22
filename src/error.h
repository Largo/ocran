#define EXIT_CODE_FAILURE ((DWORD)-1)

void PrintDebugMessage(char *format, ...);

#if _CONSOLE
DWORD PrintFatalMessage(char *format, ...);
#define FATAL(...) PrintFatalMessage(__VA_ARGS__)
#define DEBUG(...) { if (DebugModeEnabled) PrintDebugMessage(__VA_ARGS__); }
#else
DWORD PrintFatalMessageBox(char *format, ...);
#define FATAL(...) PrintFatalMessageBox(__VA_ARGS__)
#define DEBUG(...)
#endif

DWORD PrintLastError(char *msg);
#define LAST_ERROR(msg) PrintLastError(msg)
