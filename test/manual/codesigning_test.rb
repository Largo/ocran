#!/usr/bin/env ruby
# frozen_string_literal: true

# Manual Code Signing Test for Ocran
#
# This script tests REAL Windows Authenticode code signing with Ocran executables.
# It is NOT part of the automated test suite and must be run manually.
#
# Requirements:
# - Windows OS
# - Windows SDK (will be installed if not found)
# - Administrator privileges (for certificate creation)
#
# Usage:
#   ruby test/manual/codesigning_test.rb [path_to_exe]
#
# If no exe path is provided, it will build a test executable first.
#

require 'fileutils'
require 'open-uri'
require 'open3'
require 'tmpdir'

# --- Configuration ---
CERT_NAME = "OcranTestCertificate"
SCRIPT_DIR = File.dirname(__FILE__)
TEST_ROOT = File.expand_path('..', SCRIPT_DIR)
PROJECT_ROOT = File.expand_path('..', TEST_ROOT)
OCRAN_EXE = File.join(PROJECT_ROOT, 'exe', 'ocran')
FIXTURE_DIR = File.join(TEST_ROOT, 'fixtures', 'helloworld')
TEST_SCRIPT = File.join(FIXTURE_DIR, 'helloworld.rb')

# --- Helper Functions ---

# Check if running on Windows
def windows?
  /cygwin|mswin|mingw|bccwin|wince|emx/ =~ RUBY_PLATFORM
end

# Find the latest version of SignTool.exe
def find_signtool
  windows_kits_path = File.join(ENV['ProgramFiles(x86)'].sub('\\', '/') || 'C:/Program Files (x86)', 'Windows Kits', '10', 'bin')
  return nil unless Dir.exist?(windows_kits_path)

  latest_version = Dir.glob(File.join(windows_kits_path, '*')).select { |f| File.directory? f }.max
  return nil unless latest_version

  signtool_path = File.join(latest_version, 'x64', 'signtool.exe')
  File.exist?(signtool_path) ? signtool_path : nil
end

# Download and install the Windows SDK silently
def install_sdk
  puts "=" * 80
  puts "Windows SDK not found. Downloading and installing..."
  puts "=" * 80
  sdk_url = 'https://go.microsoft.com/fwlink/?linkid=2120843' # URL for Windows 10 SDK installer
  installer_path = File.join(Dir.tmpdir, 'winsdk_setup.exe')

  begin
    puts "Downloading SDK installer..."
    URI.open(sdk_url) do |remote_file|
      File.open(installer_path, 'wb') do |local_file|
        local_file.write(remote_file.read)
      end
    end

    puts "Installing SDK... This might take several minutes."
    puts "Installing only the signing tools to minimize installation size."
    # Silent install with only the signing tools
    install_command = "\"#{installer_path}\" /q /norestart /features OptionId.SigningTools"
    stdout, stderr, status = Open3.capture3(install_command)

    unless status.success?
      puts "SDK installation failed. Please try installing it manually."
      puts "Error: #{stderr}"
      puts "You can download it from: https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/"
      exit 1
    end

    puts "SDK installed successfully."
  ensure
    FileUtils.rm_f(installer_path)
  end
end

# Check if certificate already exists
def certificate_exists?
  ps_command = "Get-ChildItem -Path Cert:\\CurrentUser\\My | Where-Object { $_.Subject -match '#{CERT_NAME}' } | Select-Object -First 1"
  stdout, stderr, status = Open3.capture3("powershell -command \"#{ps_command}\"")
  status.success? && !stdout.strip.empty?
end

# Create a self-signed certificate using PowerShell
def create_certificate
  if certificate_exists?
    puts "Certificate '#{CERT_NAME}' already exists. Skipping creation."
    return
  end

  puts "Creating a self-signed certificate..."
  ps_command = "New-SelfSignedCertificate -DnsName '#{CERT_NAME}' -Type CodeSigning -CertStoreLocation Cert:\\CurrentUser\\My"
  stdout, stderr, status = Open3.capture3("powershell -command \"#{ps_command}\"")

  unless status.success?
    puts "Certificate creation failed."
    puts "Error: #{stderr}"
    puts "\nNote: You may need to run this script as Administrator."
    exit 1
  end

  puts "Certificate '#{CERT_NAME}' created successfully."
end

# Sign the executable
def sign_executable(signtool_path, exe_path)
  puts "\nSigning '#{File.basename(exe_path)}'..."

  # Command to sign with the created certificate and add a timestamp
  # Using /n to specify certificate by subject name
  sign_command = "\"#{signtool_path}\" sign /n \"#{CERT_NAME}\" /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 \"#{exe_path}\""

  stdout, stderr, status = Open3.capture3(sign_command)

  if status.success?
    puts "✓ Successfully signed '#{File.basename(exe_path)}'."
    puts stdout if stdout && !stdout.empty?
    return true
  else
    puts "✗ Signing failed."
    puts "STDOUT: #{stdout}" if stdout && !stdout.empty?
    puts "STDERR: #{stderr}" if stderr && !stderr.empty?
    return false
  end
end

# Verify the signature
def verify_signature(signtool_path, exe_path)
  puts "\nVerifying signature on '#{File.basename(exe_path)}'..."

  verify_command = "\"#{signtool_path}\" verify /pa \"#{exe_path}\""
  stdout, stderr, status = Open3.capture3(verify_command)

  if status.success?
    puts "✓ Signature verification successful."
    puts stdout if stdout && !stdout.empty?
    return true
  else
    puts "✗ Signature verification failed."
    puts "STDOUT: #{stdout}" if stdout && !stdout.empty?
    puts "STDERR: #{stderr}" if stderr && !stderr.empty?
    return false
  end
end

# Test if executable runs correctly
def test_executable(exe_path, description)
  puts "\nTesting #{description}..."

  stdout, stderr, status = Open3.capture3("\"#{exe_path}\"")

  if status.success?
    puts "✓ #{description} executed successfully."
    puts "Output: #{stdout}" if stdout && !stdout.empty?
    return true
  else
    puts "✗ #{description} failed to execute."
    puts "Exit code: #{status.exitstatus}"
    puts "STDOUT: #{stdout}" if stdout && !stdout.empty?
    puts "STDERR: #{stderr}" if stderr && !stderr.empty?
    return false
  end
end

# Build test executable
def build_test_executable
  puts "\nBuilding test executable..."

  Dir.chdir(FIXTURE_DIR) do
    # Clean up any existing executables
    cleanup(File.join(FIXTURE_DIR, 'helloworld.exe'))
    build_command = "ruby \"#{OCRAN_EXE}\" helloworld.rb --no-lzma --quiet"
    stdout, stderr, status = Open3.capture3(build_command)

    unless status.success?
      puts "Failed to build test executable."
      puts "STDOUT: #{stdout}" if stdout && !stdout.empty?
      puts "STDERR: #{stderr}" if stderr && !stderr.empty?
      exit 1
    end

    exe_path = File.join(FIXTURE_DIR, 'helloworld.exe')
    if File.exist?(exe_path)
      puts "✓ Test executable built: #{exe_path}"
      return exe_path
    else
      puts "✗ Build succeeded but executable not found."
      exit 1
    end
  end
end

# Clean up test files
def cleanup(exe_path)
  puts "\nCleaning up test files..."
  FileUtils.rm_f(exe_path) if exe_path && File.exist?(exe_path)
  signed_path = exe_path.sub('.exe', '-signed.exe')
  FileUtils.rm_f(signed_path) if signed_path && File.exist?(signed_path)
  puts "✓ Cleanup complete."
end

# --- Main Execution ---

# Only run if this file is executed directly, not when required by test suite
if __FILE__ == $0

puts "=" * 80
puts "OCRAN MANUAL CODE SIGNING TEST"
puts "=" * 80

unless windows?
  puts "\n✗ ERROR: This script is intended to run on Windows only."
  exit 1
end

# Get or build executable to test
exe_path = ARGV[0]

if exe_path && File.exist?(exe_path)
  puts "\nUsing provided executable: #{exe_path}"
else
  if exe_path
    puts "\n✗ ERROR: Provided executable not found: #{exe_path}"
    exit 1
  end
  puts "\nNo executable provided, building test executable..."
  exe_path = build_test_executable
end

# Create signed copy path
signed_exe_path = exe_path.sub('.exe', '-signed.exe')
FileUtils.cp(exe_path, signed_exe_path)

# Find or install SignTool
puts "\nLocating SignTool.exe..."
signtool = find_signtool

unless signtool
  puts "SignTool not found. Installing Windows SDK..."
  install_sdk
  signtool = find_signtool
  unless signtool
    puts "\n✗ ERROR: Could not find SignTool.exe even after installation."
    puts "Please install Windows SDK manually from:"
    puts "https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/"
    cleanup(signed_exe_path)
    exit 1
  end
end

puts "✓ Found SignTool: #{signtool}"

# Create certificate
puts "\n" + "=" * 80
puts "STEP 1: Certificate Setup"
puts "=" * 80
create_certificate

# Test unsigned executable
puts "\n" + "=" * 80
puts "STEP 2: Test Unsigned Executable"
puts "=" * 80
unsigned_works = test_executable(exe_path, "unsigned executable")

# Sign the executable
puts "\n" + "=" * 80
puts "STEP 3: Sign Executable"
puts "=" * 80
signing_succeeded = sign_executable(signtool, signed_exe_path)

unless signing_succeeded
  puts "\n✗ OVERALL RESULT: FAILED - Could not sign executable"
  cleanup(signed_exe_path)
  exit 1
end

# Verify signature
puts "\n" + "=" * 80
puts "STEP 4: Verify Signature"
puts "=" * 80
verification_succeeded = verify_signature(signtool, signed_exe_path)

# Test signed executable
puts "\n" + "=" * 80
puts "STEP 5: Test Signed Executable"
puts "=" * 80
signed_works = test_executable(signed_exe_path, "signed executable")

# Report results
puts "\n" + "=" * 80
puts "TEST RESULTS SUMMARY"
puts "=" * 80
puts "Unsigned executable works: #{unsigned_works ? '✓ PASS' : '✗ FAIL'}"
puts "Signing succeeded:         #{signing_succeeded ? '✓ PASS' : '✗ FAIL'}"
puts "Signature verified:        #{verification_succeeded ? '✓ PASS' : '✗ FAIL'}"
puts "Signed executable works:   #{signed_works ? '✓ PASS' : '✗ FAIL'}"
puts "=" * 80

if unsigned_works && signing_succeeded && verification_succeeded && signed_works
  puts "\n✓ OVERALL RESULT: SUCCESS"
  puts "Ocran executables can be code signed and continue to work correctly!"
  cleanup(signed_exe_path) unless ARGV[0] # Only cleanup if we built the exe
  exit 0
else
  puts "\n✗ OVERALL RESULT: FAILED"
  puts "One or more test steps failed. See details above."
  cleanup(signed_exe_path) unless ARGV[0]
  exit 1
end

end # if __FILE__ == $0
