#include <stdbool.h>
#include <stddef.h>

typedef enum {
    OP_CREATE_DIRECTORY = 1,
    OP_CREATE_FILE      = 2,
    OP_SETENV           = 3,
    OP_SET_SCRIPT       = 4,
    OP_CREATE_SYMLINK   = 5,
} Opcode;

/**
 * OperationModes defines a set of flags used to control various aspects of the
 * program's behavior during runtime. These flags enable or disable specific
 * features and functionalities, allowing for a more flexible and customizable
 * execution based on the needs of the user or the environment.
 *
 * The flags managed by OperationModes include, but are not limited to:
 *
 * - DEBUG_MODE: Activates verbose debugging information to assist in
 *   development or troubleshooting.
 *
 * - EXTRACT_TO_EXE_DIR: Directs the program to unpack data in the same
 *   directory as the executable.
 *
 * - AUTO_CLEAN_INST_DIR: Enables automatic cleanup of the extraction
 *   directory upon program termination.
 *
 * - CHDIR_BEFORE_SCRIPT: Changes the current directory to the script's
 *   location before its execution.
 *
 * - DATA_COMPRESSED: Indicates that the main data section is compressed and
 *   requires decompression by the Ruby launcher.
 *
 * By adjusting these flags, developers and users can tailor the program's
 * execution to suit specific scenarios, enhancing both usability and
 * efficiency.
 */
typedef enum {
    /**
     * Enable debug information display. Output various execution information to
     * stderr.
     */
    DEBUG_MODE          = 0x01,

    /**
     * Sets the extraction directory to the executable directory.
     * Data will be unpacked in the same location as the executable file.
     */
    EXTRACT_TO_EXE_DIR  = 0x02,

    /**
     * Enable automatic deletion of the extraction directory at the end of the
     * application. Cleanup the extracted data upon program termination.
     */
    AUTO_CLEAN_INST_DIR = 0x04,

    /**
     * Change the current directory to the location of the script before
     * executing the script. This allows file operations relative to that
     * directory.
     */
    CHDIR_BEFORE_SCRIPT = 0x08,

    /**
     * Indicates that the main data section is compressed. The Ruby launcher
     * will decompress this data before processing opcodes.
     */
    DATA_COMPRESSED     = 0x10,
} OperationModes;

bool IsDebugMode(OperationModes modes);
bool IsExtractToExeDir(OperationModes modes);
bool IsAutoCleanInstDir(OperationModes modes);
bool IsChdirBeforeScript(OperationModes modes);
bool IsDataCompressed(OperationModes modes);

typedef struct UnpackContext UnpackContext;

UnpackContext *OpenPackFile(const char *self_path);

bool ClosePackFile(UnpackContext *context);

OperationModes GetOperationModes(const UnpackContext *context);

/**
 * @brief Returns the file offset of the main data section.
 *
 * The main data section contains opcodes processed by the Ruby launcher
 * (gems, source files, environment variables, script info).
 *
 * @param context A valid UnpackContext returned by OpenPackFile.
 * @return File offset in bytes, or 0 if context is NULL.
 */
size_t GetMainDataOffset(const UnpackContext *context);

/**
 * @brief Returns the size of the main data section in bytes.
 *
 * If compression is enabled (DATA_COMPRESSED flag), this is the compressed
 * size. The Ruby launcher handles decompression.
 *
 * @param context A valid UnpackContext returned by OpenPackFile.
 * @return Size in bytes, or 0 if context is NULL or no main data exists.
 */
size_t GetMainDataSize(const UnpackContext *context);

bool ProcessImage(const UnpackContext *context);
