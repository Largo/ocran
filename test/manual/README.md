# Manual Tests for Ocran

This directory contains manual tests that are NOT part of the automated test suite and must be run explicitly.

These tests are separated from the main test suite to avoid:
- Running tests that require special permissions or setup
- Running tests that take a long time
- Running tests that require external tools or internet connectivity
- Failing automated builds due to environment-specific issues

## Code Signing Test

### Overview

The `codesigning_test.rb` script tests **real** Windows Authenticode code signing with Ocran executables. This verifies that executables built by Ocran can be properly signed and continue to function after signing.

### Requirements

- **Operating System**: Windows (Windows 10 or later recommended)
- **Privileges**: Administrator privileges (required for certificate creation)
- **Dependencies**:
  - Windows SDK (will be automatically installed if not found)
  - Ruby (already required for Ocran)

### Usage

#### Basic Usage (Auto-build test executable)

```bash
ruby test/manual/codesigning_test.rb
```

This will:
1. Build a test executable from `test/fixtures/helloworld/helloworld.rb`
2. Create a self-signed certificate for testing
3. Sign the executable
4. Verify the signature
5. Test that both unsigned and signed executables work
6. Clean up test files

#### Advanced Usage (Test specific executable)

```bash
ruby test/manual/codesigning_test.rb path/to/your/app.exe
```

This will test signing on a specific executable you provide.

### What the Test Does

1. **Certificate Setup**: Creates a self-signed code signing certificate named "OcranTestCertificate" (or reuses existing)
2. **Test Unsigned**: Verifies the unsigned executable runs correctly
3. **Sign Executable**: Signs the executable using Windows SignTool with SHA256 and timestamp
4. **Verify Signature**: Uses SignTool to verify the digital signature
5. **Test Signed**: Verifies the signed executable still runs correctly

### Expected Output

```
================================================================================
OCRAN MANUAL CODE SIGNING TEST
================================================================================

...

================================================================================
TEST RESULTS SUMMARY
================================================================================
Unsigned executable works: ✓ PASS
Signing succeeded:         ✓ PASS
Signature verified:        ✓ PASS
Signed executable works:   ✓ PASS
================================================================================

✓ OVERALL RESULT: SUCCESS
Ocran executables can be code signed and continue to work correctly!
```

### Troubleshooting

#### "Certificate creation failed"

You need to run the script as Administrator. Right-click on your terminal and select "Run as Administrator".

#### "Could not find SignTool.exe"

The script will attempt to install the Windows SDK automatically. If this fails:

1. Download the Windows SDK manually from: https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/
2. Install with the "Signing Tools" feature selected
3. Run the script again

#### "Signing failed"

Common causes:
- Certificate was not created successfully (check Step 1 output)
- Network issues preventing timestamp server access
- Insufficient permissions

### Notes

- The test certificate created is **self-signed** and only for testing purposes
- For production code signing, use a certificate from a trusted Certificate Authority
- The test does NOT run as part of `rake test` - it must be executed manually
- Test files are automatically cleaned up unless you provide a custom executable path

## Adding More Manual Tests

To add additional manual tests:

1. Create a new script in the `test/` directory
2. Name it with the prefix `manual_` (e.g., `manual_performance_test.rb`)
3. Document it in this file
4. Ensure it does NOT get picked up by the normal test suite (avoid `test_*.rb` pattern in root test directory)
