require "zlib"

data = "Hello, World!"
compressed = Zlib::Deflate.deflate(data)
decompressed = Zlib::Inflate.inflate(compressed)
raise "zlib round-trip failed: got #{decompressed.inspect}" unless decompressed == data
puts "zlib OK" unless defined?(Ocran)
