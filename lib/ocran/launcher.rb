# frozen_string_literal: true
#
# OCRAN Hybrid Launcher (Phase B)
#
# This script is packed into the executable and launched by the C stub
# after the bootstrap section (Ruby interpreter, this script, shared libs)
# has been extracted. It reads the main data section from the executable,
# optionally decompresses it, processes all opcodes (directories, files,
# environment variables, symlinks, script info), and then launches the
# user's application.
#
# This script must not use `require` since it runs before the full Ruby
# standard library is available. Only Ruby built-in features are used.
#
# Environment variables (set by the C stub):
#   OCRAN_EXECUTABLE      - Path to the packed executable
#   OCRAN_INST_DIR        - Extraction directory path
#   OCRAN_OPERATION_MODES - Operation mode flags (integer)
#   OCRAN_DATA_OFFSET     - File offset of main data section
#   OCRAN_DATA_SIZE       - Size of main data section (compressed if applicable)

exe_path = ENV["OCRAN_EXECUTABLE"]
inst_dir = ENV.delete("OCRAN_INST_DIR")
modes = (ENV.delete("OCRAN_OPERATION_MODES") || "0").to_i
data_offset = (ENV.delete("OCRAN_DATA_OFFSET") || "0").to_i
data_size = (ENV.delete("OCRAN_DATA_SIZE") || "0").to_i
debug = (modes & 0x01) != 0 || ENV.key?("OCRAN_DEBUG")

# Recursive mkdir without requiring fileutils
mkdir_p = ->(path) {
  return if Dir.exist?(path)
  parent = File.dirname(path)
  mkdir_p.(parent) unless parent == path || Dir.exist?(parent)
  Dir.mkdir(path)
}

# If no main data, skip to launcher (bootstrap-only mode)
if data_size > 0
  # Read main data from executable
  $stderr.puts "DEBUG: Reading main data: offset=#{data_offset}, size=#{data_size}" if debug
  data = File.open(exe_path, "rb") do |f|
    f.seek(data_offset)
    f.read(data_size)
  end

  # Decompress if DATA_COMPRESSED flag is set
  if (modes & 0x10) != 0
    $stderr.puts "DEBUG: Decompressing main data (#{data.bytesize} compressed bytes)" if debug

    # Find decompression command (lzma or xz)
    lzma_cmd = nil
    [
      ["lzma", "--decompress", "--stdout"],
      ["xz", "--format=lzma", "--decompress", "--stdout"],
    ].each do |cmd|
      # Use a simple existence check via attempting to run --help
      begin
        IO.popen(cmd + ["--help"], err: [:child, :out]) { |io| io.read }
        lzma_cmd = cmd
        break
      rescue Errno::ENOENT
        next
      end
    end

    unless lzma_cmd
      $stderr.puts "FATAL: No lzma or xz decompression command found"
      exit 1
    end

    $stderr.puts "DEBUG: Using decompressor: #{lzma_cmd.inspect}" if debug

    decompressed = IO.popen(lzma_cmd, "r+b") do |io|
      writer = Thread.new {
        io.write(data)
        io.close_write
      }
      result = io.read
      writer.join
      result
    end

    unless $?.success?
      $stderr.puts "FATAL: LZMA decompression failed"
      exit 1
    end

    $stderr.puts "DEBUG: Decompressed to #{decompressed.bytesize} bytes" if debug
    data = decompressed
  end

  # Process opcodes from main data
  pos = 0
  script_info = nil

  while pos < data.bytesize
    opcode = data.getbyte(pos)
    pos += 1

    case opcode
    when 1 # OP_CREATE_DIRECTORY
      len = data.byteslice(pos, 4).unpack1("V"); pos += 4
      name = data.byteslice(pos, len - 1); pos += len
      path = File.join(inst_dir, name)
      $stderr.puts "DEBUG: OP_CREATE_DIRECTORY: #{name}" if debug
      mkdir_p.(path)

    when 2 # OP_CREATE_FILE
      len = data.byteslice(pos, 4).unpack1("V"); pos += 4
      name = data.byteslice(pos, len - 1); pos += len
      file_size = data.byteslice(pos, 4).unpack1("V"); pos += 4
      content = data.byteslice(pos, file_size); pos += file_size
      path = File.join(inst_dir, name)
      $stderr.puts "DEBUG: OP_CREATE_FILE: #{name} (#{file_size} bytes)" if debug
      dir = File.dirname(path)
      mkdir_p.(dir)
      File.binwrite(path, content)

    when 3 # OP_SETENV
      len = data.byteslice(pos, 4).unpack1("V"); pos += 4
      name = data.byteslice(pos, len - 1); pos += len
      len = data.byteslice(pos, 4).unpack1("V"); pos += 4
      value = data.byteslice(pos, len - 1); pos += len
      # Replace placeholder | with inst_dir
      value = value.gsub("|", inst_dir)
      $stderr.puts "DEBUG: OP_SETENV: #{name}=#{value}" if debug
      ENV[name] = value

    when 4 # OP_SET_SCRIPT
      size = data.byteslice(pos, 4).unpack1("V"); pos += 4
      script_data = data.byteslice(pos, size); pos += size
      # Parse double-null-terminated string list
      script_info = []
      sp = 0
      while sp < script_data.bytesize
        nul = script_data.index("\0".b, sp)
        break unless nul
        s = script_data.byteslice(sp, nul - sp)
        break if s.empty?
        script_info << s
        sp = nul + 1
      end
      $stderr.puts "DEBUG: OP_SET_SCRIPT: #{script_info.inspect}" if debug

    when 5 # OP_CREATE_SYMLINK
      len = data.byteslice(pos, 4).unpack1("V"); pos += 4
      link_name = data.byteslice(pos, len - 1); pos += len
      len = data.byteslice(pos, 4).unpack1("V"); pos += 4
      target = data.byteslice(pos, len - 1); pos += len
      link_path = File.join(inst_dir, link_name)
      $stderr.puts "DEBUG: OP_CREATE_SYMLINK: #{link_name} -> #{target}" if debug
      begin
        File.symlink(target, link_path) unless File.symlink?(link_path)
      rescue NotImplementedError
        $stderr.puts "DEBUG: OP_CREATE_SYMLINK: skipped (not supported)" if debug
      end

    else
      $stderr.puts "FATAL: Unknown opcode #{opcode} at position #{pos - 1}"
      exit 1
    end
  end
else
  script_info = nil
  $stderr.puts "DEBUG: No main data section, skipping opcode processing" if debug
end

# Launch the user's script
unless script_info && script_info.size >= 2
  $stderr.puts "DEBUG: No script info set, exiting" if debug
  exit 0
end

app = File.join(inst_dir, script_info[0])
script = File.join(inst_dir, script_info[1])
extra = script_info[2..] || []

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
