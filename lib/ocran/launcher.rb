# frozen_string_literal: true
#
# OCRAN Hybrid Launcher
#
# This script is packed into the executable and launched by the C stub
# after all files have been extracted. It reads script metadata from a
# file written by the C stub and launches the user's application.
#
# This script must not use `require` since it may run before the full
# Ruby standard library is available in future phases of the hybrid
# approach. Only Ruby built-in features are used.
#
# Environment variables (set by the C stub):
#   OCRAN_EXECUTABLE      - Path to the packed executable
#   OCRAN_INST_DIR        - Extraction directory path
#   OCRAN_OPERATION_MODES - Operation mode flags (integer)

inst_dir = ENV.delete("OCRAN_INST_DIR")
modes = (ENV.delete("OCRAN_OPERATION_MODES") || "0").to_i
debug = (modes & 0x01) != 0 || ENV.key?("OCRAN_DEBUG")

# Read script info file written by the C stub.
# Format: double-null-terminated list of strings
#   "app_path\0script_path\0extra_arg1\0...\0\0"
info_path = File.join(inst_dir, "ocran_script.info")
unless File.exist?(info_path)
  $stderr.puts "DEBUG: No script info file, exiting" if debug
  exit 0
end

data = File.binread(info_path)

# Parse double-null-terminated string list
args = []
pos = 0
while pos < data.bytesize
  nul = data.index("\0".b, pos)
  break unless nul
  s = data.byteslice(pos, nul - pos)
  break if s.empty? # double-null terminator reached
  args << s
  pos = nul + 1
end

if args.size < 2
  $stderr.puts "FATAL: Script info must contain at least application and script paths"
  exit 1
end

app = File.join(inst_dir, args[0])
script = File.join(inst_dir, args[1])
extra = args[2..] || []

if debug
  $stderr.puts "DEBUG: Launcher: app=#{app}"
  $stderr.puts "DEBUG: Launcher: script=#{script}"
  $stderr.puts "DEBUG: Launcher: extra=#{extra.inspect}"
  $stderr.puts "DEBUG: Launcher: ARGV=#{ARGV.inspect}"
end

# Build the command to exec
cmd = [app]

# Handle --chdir-first: change to script directory before execution
if (modes & 0x08) != 0
  dir = File.dirname(script)
  $stderr.puts "DEBUG: Launcher: chdir to #{dir}" if debug
  cmd.push("-C", dir, "--")
end

cmd.push(script, *extra, *ARGV)

$stderr.puts "DEBUG: Launcher: exec #{cmd.inspect}" if debug

# Replace this process with the user's application
exec(*cmd)
