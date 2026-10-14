# Packs a runtime directory (the out/ of a runtime build) into a
# reproducible .tar.gz for distribution: sorted entries, fixed times
# (SOURCE_DATE_EPOCH), no owners, file modes kept; stage/ and exts/ (build
# leftovers) are left out. Prints the archive's path and SHA-256.
#
#   ruby runtime/pack-runtime.rb RUNTIME_DIR [OUT_DIR]
#
# The archive is named after runtime.json:
# ocran-runtime-<ruby version>-<arch>.tar.gz, with one top-level directory
# of the same name.
require "json"
require "zlib"
require "digest"
require "rubygems/package"

dir, out_dir = ARGV
abort "usage: pack-runtime.rb RUNTIME_DIR [OUT_DIR]" unless dir && File.file?(File.join(dir, "runtime.json"))
info = JSON.parse(File.read(File.join(dir, "runtime.json")))
name = "ocran-runtime-#{info.fetch("ruby_version")}-#{info.fetch("arch")}"
path = File.join(out_dir || ".", "#{name}.tar.gz")
# TarWriter dates every entry Gem.source_date_epoch, read from here.
ENV["SOURCE_DATE_EPOCH"] ||= "1767225600"
mtime = Integer(ENV["SOURCE_DATE_EPOCH"])

entries = Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject do |rel|
  rel.split("/").last.match?(/\A\.\.?\z/) || rel.match?(%r{\A(stage|exts)(/|\z)})
end.sort

File.open(path, "wb") do |file|
  gz = Zlib::GzipWriter.new(file, Zlib::BEST_COMPRESSION)
  gz.mtime = mtime # 0 would mean "now" to GzipWriter
  Gem::Package::TarWriter.new(gz) do |tar|
    entries.each do |rel|
      full = File.join(dir, rel)
      target = "#{name}/#{rel}"
      if File.symlink?(full)
        tar.add_symlink(target, File.readlink(full), 0o777)
      elsif File.directory?(full)
        tar.mkdir(target, 0o755)
      else
        mode = File.executable?(full) || rel.end_with?(".exe", ".dll") ? 0o755 : 0o644
        tar.add_file_simple(target, mode, File.size(full)) { |io| File.open(full, "rb") { |f| IO.copy_stream(f, io) } }
      end
    end
  end
  gz.finish
end
puts "#{Digest::SHA256.file(path).hexdigest}  #{path}"
