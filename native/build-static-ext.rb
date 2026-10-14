# Compiles one C extension (a gem's ext/<name>/ directory) into a static
# library for the ocran runtime, the way RubyGems would build it - extconf.rb
# then make - except that mkmf targets the cross-built runtime and produces
# a .a instead of a .so.
#
# Cross builds (MinGW) run it under the build host's Ruby with the cross
# build's fake.rb, which makes RbConfig describe the Windows target; native
# builds (mswin) under the freshly built and installed Ruby itself:
#
#   ruby --disable=gems -I$BUILD -r$BUILD/<arch>-fake native/build-static-ext.rb \
#        RUBY_BUILD_DIR RUBY_SRC_DIR EXT_SRC_DIR OUT_DIR [extconf args...]
#
# Prints "<feature> <Init function> <archive> <libs>" on success, for the
# runtime link (see build-runtime.sh).
require "rbconfig"
require "fileutils"

build, src, ext_src, out, *extconf_args = ARGV
abort "usage: see header" unless out

# Headers and libruby come from the build tree, not from an installation.
arch = RbConfig::CONFIG["arch"]
{
  "rubyhdrdir" => File.join(src, "include"),
  "rubyarchhdrdir" => File.join(build, ".ext/include", arch),
  "libdir" => build,
  "prefix" => build,
}.each { |k, v| RbConfig.fire_update!(k, v) }

# Built inside a copy of the whole gem, as RubyGems does: extconf.rb files
# may reach into the gem's lib/ (racc's does).
ext_src = File.expand_path(ext_src)
gem_root, sep, ext_rel = ext_src.rpartition("/ext/")
gem_root, ext_rel = File.dirname(ext_src), File.basename(ext_src) if sep.empty?
ext_rel = File.join("ext", ext_rel) unless sep.empty?
FileUtils.rm_rf(out)
FileUtils.mkdir_p(File.dirname(out))
FileUtils.cp_r(gem_root, out)
Dir.chdir(File.join(out, ext_rel))

$0 = File.expand_path("extconf.rb") # mkmf takes srcdir from $0
ARGV.replace(extconf_args)
require "mkmf"
$static = true # after require: loading mkmf resets it
load "./extconf.rb"

mk = File.read("Makefile")
target = mk[/^TARGET = (\S+)/, 1] or abort "#{ext_src}: extconf.rb produced no TARGET"
prefix = mk[/^target_prefix = (\S*)/, 1].to_s.delete_prefix("/")
feature = [prefix, target].reject(&:empty?).join("/")
libs = mk[/^LIBS = (.*)$/, 1].split.reject { |l| l.include?("$(RUBY_SO_NAME)") || l.include?("$(LIBRUBY") }
lib = "#{target}.#{RbConfig::CONFIG["LIBEXT"]}"
if RbConfig::CONFIG["target_os"].start_with?("mswin")
  system("nmake", "-nologo", "STATIC_LIB=#{lib}", lib, exception: true)
else
  system("make", "-j#{ENV.fetch("JOBS", "4")}", "STATIC_LIB=#{lib}", lib, exception: true)
end
puts [feature, "Init_#{target}", File.join(Dir.pwd, lib), libs.join(",")].join(" ")
