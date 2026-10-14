# Prototype packer for the native no-extraction runtime (not yet wired into
# the ocran CLI):
#
#   ruby native/pack-prototype.rb RUNTIME.exe STDLIB_DIR OUT.exe MAIN.rb [FILE...]
#
# Writes OUT.exe = RUNTIME.exe + a ZIP archive holding ocran/boot.rb,
# ocran/config.rb, the standard library under lib/ruby/<ver>/ and the
# application under src/.
require_relative "../lib/ocran/zip_writer"
require "fileutils"

# ZIP stores local time; packing in UTC makes the archive independent of
# the packaging machine's time zone.
ENV["TZ"] = "UTC"

runtime, stdlib, out, main, *extra = ARGV
abort File.read(__FILE__)[/^#   ruby.*$/] unless main

mtime = Time.at(Integer(ENV.fetch("SOURCE_DATE_EPOCH", "1767225600")))
entry = ->(name, **kw) { Ocran::ZipWriter::Entry.new(name: name, mtime: mtime, **kw) }

ruby_ver = File.basename(stdlib)
entries = []
entries << entry.("ocran/boot.rb", source: File.join(__dir__, "boot.rb"))
config = {
  main: "src/#{File.basename(main)}",
  load_path: ["src", "lib/ruby/site_ruby/#{ruby_ver}", "lib/ruby/#{ruby_ver}"],
  env: {},
  rubygems: ENV["OCRAN_RUBYGEMS"] == "1",
}
entries << entry.("ocran/config.rb", data: config.inspect + "\n")
entries << entry.("src/#{File.basename(main)}", source: main)
extra.each { |f| entries << entry.("src/#{File.basename(f)}", source: f) }
# Bundled gems (fiddle, bigdecimal, ...): their lib/ directories go on the
# load path directly, as RubyGems would put them there on activation.
gems_dir = File.expand_path("../gems/#{ruby_ver}/gems", stdlib)
Dir.glob("*/lib", base: gems_dir).sort.each do |lib|
  config[:load_path] << "lib/ruby/gems/#{ruby_ver}/gems/#{lib}"
  Dir.glob("**/*", base: File.join(gems_dir, lib)).sort.each do |rel|
    path = File.join(gems_dir, lib, rel)
    next unless File.file?(path)
    entries << entry.("lib/ruby/gems/#{ruby_ver}/gems/#{lib}/#{rel}", source: path)
  end
end
entries[1] = entry.("ocran/config.rb", data: config.inspect + "\n")
Dir.glob("**/*", base: stdlib).sort.each do |rel|
  path = File.join(stdlib, rel)
  next unless File.file?(path)
  entries << entry.("lib/ruby/#{ruby_ver}/#{rel}", source: path)
end

# Directory entries too get the fixed time (ZipWriter would add them with
# the current time).
dirs = entries.flat_map { |e| e.name.split("/")[0...-1].each_index.map { |i| e.name.split("/")[0..i].join("/") + "/" } }.uniq
entries = dirs.map { |d| entry.(d) } + entries

FileUtils.cp(runtime, out)
File.open(out, "ab") do |io|
  # An empty archive, so ZipWriter.append writes the first entries right
  # after the executable, with offsets relative to the start of the file.
  io.write(Ocran::ZipWriter.end_of_central_directory(0, 0, io.size))
end
Ocran::ZipWriter.append(out, entries)
puts "#{out}: #{entries.size} entries, #{File.size(out)} bytes"
