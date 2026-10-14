# Compiles one C extension (a gem's ext/<name>/ directory) into a static
# library for an ocran static runtime, the way RubyGems would build it -
# extconf.rb then make - except that mkmf targets the runtime and produces
# a static library instead of a DLL.
#
# Runs in a process of its own (mkmf is global state), under a Ruby whose
# RbConfig describes the runtime: for MinGW, any Ruby with the runtime's
# <arch>-fake.rb loaded (Ruby's own cross-build mechanism); for mswin, the
# runtime build's own Ruby.
#
#   ruby --disable=gems -I SDK -r SDK/<arch>-fake build_static_ext.rb \
#        INCLUDE_DIR ARCH_INCLUDE_DIR EXT_SRC_DIR OUT_DIR [extconf args...]
#
# INCLUDE_DIR holds ruby.h, ARCH_INCLUDE_DIR ruby/config.h. The compiler is
# RbConfig's, or OCRAN_RUNTIME_CC (with the matching ar and ranlib) when the
# build host names it differently; OCRAN_RUNTIME_LIBS are appended to $LIBS.
# Prints
#   <feature> <Init function> <archive> <comma-separated libs>
# on success, for the runtime link (Ocran::RuntimeSdk#link).
require "rbconfig"
require "fileutils"

include_dir, arch_include_dir, ext_src, out, *extconf_args = ARGV
abort "usage: see #{__FILE__}" unless out

{
  "rubyhdrdir" => File.expand_path(include_dir),
  "rubyarchhdrdir" => File.expand_path(arch_include_dir),
}.each { |k, v| RbConfig.fire_update!(k, v) }

if (cc = ENV["OCRAN_RUNTIME_CC"]) && !cc.empty?
  tool = ->(name) { cc.sub(/(?:gcc|cc|clang)(\.exe)?\z/) { "#{name}#{$1}" } }
  { "CC" => cc, "CPP" => "#{cc} -E", "LDSHARED" => "#{cc} -shared", "AR" => tool.("ar"),
    "RANLIB" => tool.("ranlib") }.each { |k, v| RbConfig.fire_update!(k, v) }
end

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
# The static C libraries an extension's own (-lsybdb, -lxml2) need in turn -
# iconv, OpenSSL, zlib, Windows system libraries - in link order. mkmf puts
# $LIBS after the libraries extconf.rb finds, both in its link checks and
# in the Makefile, which is the order a static link needs.
$LIBS = [$LIBS, ENV["OCRAN_RUNTIME_LIBS"]].compact.join(" ")
# Defines the static libraries' headers need (LIBXSLT_STATIC, ...).
$CPPFLAGS = [$CPPFLAGS, ENV["OCRAN_RUNTIME_CPPFLAGS"]].compact.join(" ")
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
