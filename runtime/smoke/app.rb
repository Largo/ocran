# Smoke test for --static-runtime executables (see run.rb): exercises what
# the read-only archive layer must get right, and prints key=value lines.
require "json"
require "yaml"
require "openssl"
require "zlib"
require "set"
require_relative "helper"
autoload :Lazy, File.join(__dir__, "lazy")

exe = ENV["OCRAN_EXECUTABLE"]
puts "platform=#{RUBY_PLATFORM}"
puts "file_in_exe=#{exe ? __FILE__.start_with?(exe.tr("\\", "/")) : "build"}"
puts "main=#{$0 == __FILE__}"
puts "helper=#{Helper.greet}"
puts "autoload=#{Lazy::VALUE}"
puts "json=#{JSON.generate([1, { "a" => 2 }])}"
puts "yaml=#{YAML.load("x: [1, 2]")["x"].sum}"
puts "sha256=#{OpenSSL::Digest::SHA256.hexdigest("abc")[0, 16]}"
puts "zlib=#{Zlib.crc32("abc")}"
puts "data=#{File.read(File.join(__dir__, "data.txt")).strip}"
puts "glob=#{Dir.glob(File.join(__dir__, "*.rb")).map { File.basename(_1) }.sort.join(",")}"
puts "argv=#{ARGV.join("|")}"
puts "DATA=#{DATA.read.strip}" if defined?(DATA)
from_disk = exe ? $LOADED_FEATURES.select { File.absolute_path?(_1) && !_1.start_with?(exe.tr("\\", "/")) } : []
puts "from_disk=#{from_disk.size}"
exit 7
__END__
data section
