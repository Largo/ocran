/**
 * OperationModes defines a set of flags used to control various aspects of the
 * program's behavior during runtime. These flags enable or disable specific
 * features and functionalities, allowing for a more flexible and customizable
 * execution based on the needs of the user or the environment.
 *
 * The flags managed by OperationModes include, but are not limited to:
 * - DEBUG_MODE: Activates verbose debugging information to assist in development or troubleshooting.
 * - EXTRACT_TO_EXE_DIR: Directs the program to unpack data in the same directory as the executable.
 * - AUTO_CLEAN_INST_DIR: Enables automatic cleanup of the extraction directory upon program termination.
 * - CHDIR_BEFORE_SCRIPT: Changes the current directory to the script's location before its execution.
 * - DATA_COMPRESSED: Indicates that the data to be processed is compressed and requires decompression.
 *
 * By adjusting these flags, developers and users can tailor the program's execution
 * to suit specific scenarios, enhancing both usability and efficiency.
 */
typedef enum {
    /**
    * Enable debug information display. Output various execution information to stderr.
    */
    DEBUG_MODE          = 0x01, // 0b00000001

    /**
    * Sets the extraction directory to the executable directory.
    * Data will be unpacked in the same location as the executable file.
    */
    EXTRACT_TO_EXE_DIR  = 0x02, // 0b00000010

    /**
    * Enable automatic deletion of the extraction directory at the end of the application.
    * Cleanup the extracted data upon program termination.
    */
    AUTO_CLEAN_INST_DIR = 0x04, // 0b00000100

    /**
    * Change the current directory to the location of the script before executing the script.
    * This allows file operations relative to that directory.
    */
    CHDIR_BEFORE_SCRIPT = 0x08, // 0b00001000

    /**
    * Indicates that the data to be extracted is compressed. Decompression is required
    * before using the data.
    */
    DATA_COMPRESSED     = 0x10, // 0b00010000
} OperationModes;

#define IS_MODE(flags, flag) (((flags) & (flag)) == (flag))
#define IS_DEBUG_MODE_ENABLED(X)          IS_MODE((X), DEBUG_MODE)
#define IS_EXTRACT_TO_EXE_DIR_ENABLED(X)  IS_MODE((X), EXTRACT_TO_EXE_DIR)
#define IS_AUTO_CLEAN_INST_DIR_ENABLED(X) IS_MODE((X), AUTO_CLEAN_INST_DIR)
#define IS_CHDIR_BEFORE_SCRIPT_ENABLED(X) IS_MODE((X), CHDIR_BEFORE_SCRIPT)
#define IS_DATA_COMPRESSED(X)             IS_MODE((X), DATA_COMPRESSED)
