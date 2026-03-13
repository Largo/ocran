# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OCRAN (One-Click Ruby Application Next) is a Windows executable builder for Ruby applications. It packages Ruby scripts, the Ruby interpreter, gems, and DLLs into a single `.exe` file. This is a fork of OCRA, maintained for Ruby 3.2+ compatibility.

## Development Commands

### Building

```bash
rake build          # Compile C stub executables (stub.exe, stubw.exe, edicon.exe)
```

**Requirements for building stubs:**
- Windows with RubyInstaller DevKit (mingw-w64)
- Run `bin/setup` first to install dependencies and build stubs initially

### Testing

```bash
rake test                           # Run full test suite (all tests in test/test_ocra.rb)
rake test_single[test_name]         # Run a single test (e.g., rake test_single[helloworld])
ruby -Ilib:test test/test_ocra.rb --name test_helloworld  # Alternative for single test
```

### Development Setup

```bash
bin/setup          # One-time setup: install Bundler, dev gems, and build stubs
bin/console        # Launch IRB with Ocran preloaded
```

### Manual Tests

Manual tests are in `test/manual/` and do NOT run during `rake test`:

```bash
ruby test/manual/codesigning_test.rb         # Test real Windows code signing
ruby test/manual/codesigning_test.rb app.exe # Test signing on specific exe
```

See `test/manual/README.md` for requirements (Windows SDK, admin privileges).

## Architecture Overview

### Two-Phase Execution Model

OCRAN operates in two distinct phases:

**1. Build Time (Ruby layer):**
- Entry point: `exe/ocran` → `lib/ocran/runner.rb`
- Runs the target Ruby script to detect dependencies (`Kernel#require`, `Kernel#load`)
- Analyzes gems, DLLs, and resource files
- Generates a custom opcode format with instructions (create directories, extract files, set env vars)
- Packages everything into a single `.exe` containing:
  - The C stub executable (stub.exe or stubw.exe)
  - The opcode data with all files
  - OCRAN signature (4 bytes: `0x41, 0xb6, 0xba, 0x4e`)

**2. Runtime (C stub layer):**
- Entry point: `src/stub.c` → `main()`
- Reads its own executable file to find OCRAN signature
- Extracts Ruby interpreter and scripts to temp directory (or install directory with `--chdir-first`)
- Sets `OCRAN_EXECUTABLE` environment variable
- Launches the Ruby script with proper environment

### Key Components

#### Ruby Layer (`lib/ocran/`)

- **`runner.rb`**: Main orchestrator, parses command-line options
- **`build_facade.rb`**: High-level build process coordinator
- **`library_detector.rb`**: Detects dependencies by running the target script
- **`stub_builder.rb`**: Creates the final executable by:
  - Copying the appropriate stub (console or windowed)
  - Clearing invalid PE security headers (important for code signing)
  - Writing opcode instructions
  - Appending packed data
- **`gem_spec_queryable.rb`**: Handles gem dependency resolution and file selection
- **`inno_setup_script_builder.rb`**: Generates Inno Setup installers

#### C Stub Layer (`src/`)

Modularized C code that runs inside the final `.exe`:

- **`stub.c`**: Main entry point, orchestrates extraction and execution
- **`unpack.c`**: Core unpacking logic:
  - Parses opcode format
  - Handles code-signed executables (PE header analysis)
  - Supports LZMA compression/decompression
  - **Code signing support**: Detects and handles Windows Authenticode signatures via PE header inspection
- **`system_utils.c`**: Windows API wrappers (file mapping, path utilities)
- **`inst_dir.c`**: Manages extraction directory lifecycle
- **`script_info.c`**: Stores and retrieves script execution details
- **`error.c`**: Error handling and debug output

#### Opcode Format

The packed data uses a custom bytecode format with operations:
- `OP_CREATE_DIRECTORY` (1): Create extraction directory
- `OP_CREATE_FILE` (2): Extract file with content
- `OP_SETENV` (3): Set environment variable
- `OP_SET_SCRIPT` (4): Specify script to execute

Each operation is followed by size-prefixed strings and binary data.

### Code Signing Support

OCRAN executables support Windows Authenticode code signing:

- **Build time**: `stub_builder.rb` clears invalid security directory entries from PE headers
- **Runtime**: `unpack.c` detects digital signatures and searches for OCRAN signature before the security entry
- **Testing**: Fake code signer in `test/fake_code_signer.rb` simulates signing for automated tests
- **Manual testing**: `test/manual/codesigning_test.rb` tests real signing with Windows SDK

### PE Header Handling

The codebase handles PE32+ (64-bit) executables:
- Security directory is at offset: `PE_offset + 4 + 20 + 128` (PE sig + FILE_HEADER + partial OPTIONAL_HEADER)
- Different header sizes: PE32 (224 bytes) vs PE32+ (240 bytes)
- Magic field (0x10b = PE32, 0x20b = PE32+) determines architecture

## Important Paths

```
exe/ocran              # Executable entry point
lib/ocran/runner.rb    # Main orchestrator
lib/ocran/stub_builder.rb  # Executable builder
src/stub.c             # C stub main()
src/unpack.c           # Core unpacking logic with code signing support
share/ocran/           # Prebuilt binaries (stub.exe, stubw.exe, edicon.exe, lzma.exe)
test/test_ocra.rb      # Main test suite
test/manual/           # Manual tests (not in rake test)
```

## Key Concepts

### Dependency Detection Modes

OCRAN detects dependencies by actually running the target script at build time:
- `--no-dep-run`: Skip running script (requires `--add-all-core` and `--gem-full`)
- `--no-autoload`: Don't follow `autoload` declarations
- `--no-autodll`: Disable automatic DLL detection

### Gem Inclusion Modes

Four modes control what gets included from gems:
- `--gem-minimal`: Only loaded scripts
- `--gem-guess`: Loaded scripts + important files (DEFAULT)
- `--gem-all`: All scripts + important files
- `--gem-full`: Everything in gem directory

### Stub Types

Three stub executables are built from C source:
- **stub.exe**: Console mode (uses ruby.exe)
- **stubw.exe**: Windowed mode (uses rubyw.exe, no console window)
- **edicon.exe**: Utility to change icons in executables

## Working with Tests

### Test Structure

- `test/test_ocra.rb`: Main test class (TestOcran)
- `test/fixtures/`: Test Ruby scripts (helloworld, writefile, etc.)
- `test/fake_code_signer.rb`: Simulates code signing for tests
- `test/manual/`: Manual tests requiring special setup

### Running Specific Tests

Tests are named `test_*` methods in `TestOcran`:

```bash
rake test_single[helloworld]           # Runs test_helloworld
ruby -Ilib:test test/test_ocra.rb --name test_codesigning_support
```

### Test Fixtures

Each fixture in `test/fixtures/` is a minimal Ruby project used to test specific features:
- `helloworld/`: Basic functionality
- `writefile/`: File I/O operations
- `autoload/`: Autoload detection
- `multibyte_*/`: UTF-8 path handling

## Modifying the C Stub

When changing `src/*.c` files:

1. Edit the C source files
2. Run `rake build` to recompile
3. New stubs are copied to `share/ocran/`
4. Test with `rake test` or build a test executable

The Makefile uses gcc with these key flags:
- `-DWITH_LZMA`: Enable LZMA compression support
- `-s`: Strip symbols
- `-mwindows`: Create windowed application (for stubw.exe)

## Dependencies and Bundler

OCRAN requires `bundler` for test execution (`test/test_ocra.rb` uses `Bundler.with_original_env`). The current setup uses:
- minitest 6.0+
- hoe 4.6+ (build system)
- fiddle 1.0+ (FFI for Windows APIs in Ruby)

## Common Development Patterns

### Adding New Opcodes

To add a new opcode to the packing format:

1. Define constant in both `lib/ocran/stub_builder.rb` and `src/unpack.h`
2. Add write method in `stub_builder.rb` (e.g., `write_opcode(OP_NEW_OPERATION)`)
3. Add case handler in `src/unpack.c` in `process_opcode()` function
4. Update `OP_MAX` if tracking opcode count

### Working with Windows APIs

Use existing wrappers in `src/system_utils.c` for Windows operations. Create new wrappers following the pattern:
- Error checking with detailed DEBUG messages
- Proper resource cleanup (handles, memory maps)
- Return bool for success/failure

### Handling PE Format

When working with PE executables, use `test/fake_code_signer/pe_wrapper.rb` as reference for header offsets and structure. Always validate:
- Architecture (PE32 vs PE32+) using magic field
- Bounds checking for all offsets
- File size consistency
