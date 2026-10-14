# Writes runtime.json, the description of a native runtime that ocran
# --native reads at packaging time:
#
#   ruby native/write-runtime-info.rb RUBY_BUILD_DIR RUNTIME_DIR [EXT_LINE_FILE...]
#
# RUNTIME_DIR holds ocran-runtime.exe and lib/ruby/ (the runtime's own
# standard library and bundled gems). The C extensions linked into the
# runtime are read from Ruby's generated ext/extinit.c and enc/encinit.c
# plus the gem extension lines of build_static_ext.rb, so the list is what
# was actually linked, not what was intended.
require "json"
require "digest"

build, dir, *ext_files = ARGV.map { |a| a.tr("\\", "/") } # Dir.glob wants /
abort "usage: write-runtime-info.rb RUBY_BUILD_DIR RUNTIME_DIR [EXT_LINE_FILE...]" unless dir

rbconfig = File.read(Dir[File.join(build, "rbconfig.rb")].first || abort("no rbconfig.rb in #{build}"))
config = ->(key) { rbconfig[/^\s*CONFIG\["#{key}"\] = "([^"]*)"/, 1] or abort "no #{key} in rbconfig.rb" }
version = %w[MAJOR MINOR TEENY].map(&config).join(".")
ruby_version = config.("ruby_version")
arch = config.("arch")

features = []
File.read(File.join(build, "ext/extinit.c")).scan(/init\(Init_\w+, "([^"]+)"\)/) { features << $1 }
encinit = File.read(File.join(build, "enc/encinit.c"))
encinit.scan(/^\s*provide\(\w+, "([^"]+)"\)/) { features << $1 }
encinit.scan(/^\s*init_enc\((\w+)\)/) { features << "enc/#{$1}" }
encinit.scan(/^\s*init_trans\((\w+)\)/) { features << "enc/trans/#{$1}" }
# Prism's extension is compiled into libruby itself and registers as
# prism/prism.so at startup (prism_init.c).
features << "prism/prism" if Dir[File.join(build, "prism_init.{o,obj}")].any?
ext_files.each { |f| features << File.read(f).split(" ", 2).first }
abort "no statically linked extensions found in #{build}" if features.empty?

exe = File.join(dir, "ocran-runtime.exe")
abort "#{exe} not found" unless File.file?(exe)
gems_dir = File.join(dir, "lib/ruby/gems", ruby_version)

lib = "lib/ruby"
info = {
  "format" => 1,
  "ruby_version" => version,
  "ruby_api_version" => ruby_version,
  "arch" => arch,
  "executable" => "ocran-runtime.exe",
  "executable_sha256" => Digest::SHA256.file(exe).hexdigest,
  # The runtime's default load path, in Ruby's own order.
  "load_path" => [
    "#{lib}/site_ruby/#{ruby_version}", "#{lib}/site_ruby/#{ruby_version}/#{arch}", "#{lib}/site_ruby",
    "#{lib}/vendor_ruby/#{ruby_version}", "#{lib}/vendor_ruby/#{ruby_version}/#{arch}", "#{lib}/vendor_ruby",
    "#{lib}/#{ruby_version}", "#{lib}/#{ruby_version}/#{arch}",
  ],
  "gem_dir" => "#{lib}/gems/#{ruby_version}",
  # Where RubyGems looks for gem.build_complete markers on the runtime:
  # extensions/<gem_platform>/<extension_api_version>/<gem>/.
  "gem_platform" => Gem::Platform.new(arch).to_s,
  "extension_api_version" => config.("ENABLE_SHARED") == "no" ? "#{ruby_version}-static" : ruby_version,
  # Features (as given to require) of the C extensions linked in.
  "static_features" => features.uniq.sort,
  # Gems shipped with the runtime: name => gemspec path relative to gem_dir
  # (specifications/default/... for default gems).
  "gems" => Dir[File.join(gems_dir, "specifications/{,default/}*.gemspec")].to_h { |spec|
    [File.basename(spec, ".gemspec").sub(/-[^-]+\z/, ""), spec.delete_prefix("#{gems_dir}/")]
  }.sort.to_h,
}
File.write(File.join(dir, "runtime.json"), JSON.pretty_generate(info) + "\n")
puts "#{File.join(dir, "runtime.json")}: Ruby #{version} #{arch}, #{info["static_features"].size} static features, #{info["gems"].size} gems"
