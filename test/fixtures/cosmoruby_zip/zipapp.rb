# Multi-file application used to check the compiler-free ZIP packaging
# mode: it reads a resource packed next to its own sources, looks for a
# file next to the EXECUTABLE, passes ARGV through and sets an exit code.
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "zipapp/greeter"

unless defined?(Ocran)
  beside = File.join(File.dirname(ENV["OCRAN_EXECUTABLE"].to_s), "beside.txt")

  puts "platform:#{RUBY_PLATFORM}"
  puts "argv:#{ARGV.inspect}"
  puts "main:#{__FILE__ == $0}"
  puts "dir:#{__dir__}"
  puts "packed:#{ZipApp::Greeter.message}"
  puts "executable:#{ENV["OCRAN_EXECUTABLE"]}"
  puts "beside:#{File.exist?(beside) ? File.read(beside).strip : "(none)"}"
  puts "verbose:#{$VERBOSE.inspect}"

  # Option-shaped or not, every argument reaches the application: a packed
  # binary claims none of its command line.
  exit 3 if ARGV.include?("fail") || ARGV.include?("--fail")
end
