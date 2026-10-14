# Captures what is needed to link the runtime again, with more C extensions,
# into a self-contained SDK directory that ships with the runtime
# (<runtime>/sdk, used by Ocran::NativeSdk at packaging time):
#
#   ruby native/make-sdk.rb RUBY_BUILD_DIR RUBY_SRC_DIR DEPS_DIR SDK_DIR [EXT_LINE_FILE...]
#
# * link.args: the ruby.exe link command from Ruby's own makefile (dry run,
#   with ocran_main.o as the main object), one argument per line, with the
#   SDK directory as @SDK@ and the place for extra objects as @EXTRA@; and
#   every input file it names.
# * include/: Ruby's headers, include/<arch>/ (and .ext/include/<arch>/,
#   where the fake.rb below expects it): ruby/config.h.
# * rbconfig.rb and <arch>-fake.rb: the target's RbConfig, as Ruby's cross
#   build uses it, made relative to the SDK directory.
# * deps/: the static C libraries and their headers, pkg-config files, and
#   the DLL builds of the LGPL libraries (deps/bin) for --native-dll.
# * sdk.json: toolchain, dependency libraries, DLLs.
# * exts/: the gem extensions linked into the runtime, and their .line files.
require "fileutils"
require "json"
require "shellwords"

build, src, deps, sdk, *ext_files = ARGV.map { |a| File.expand_path(a) }
abort "usage: make-sdk.rb RUBY_BUILD_DIR RUBY_SRC_DIR DEPS_DIR SDK_DIR [EXT_LINE_FILE...]" unless sdk

cmd = Dir.chdir(build) do
  out = IO.popen(["make", "-f", "exts.mk", "-n", "RUBY_EXP=", "MAINOBJ=ocran_main.o",
                  "EXTENCS=enc/encinit.o enc/libenc.a enc/libtrans.a", "ruby.exe",
                  err: File::NULL], &:read)
  out.lines.grep(/-o ruby\.exe\s*$/).last or abort "no link command for ruby.exe in dry run"
end
args = Shellwords.split(cmd)

FileUtils.rm_rf(sdk)
FileUtils.mkdir_p(sdk)
result = []
skip_next = false
args.each_with_index do |arg, i|
  next skip_next = false if skip_next
  case arg
  when "-o"
    skip_next = true
  when /\A-L(.*)\z/
    dir = File.expand_path($1, build)
    result << (dir == build ? "-L@SDK@" : dir == File.join(deps, "lib") ? "-L@SDK@/deps/lib" : arg)
  when /\A-/
    result << arg
  else
    if i.zero?
      result << arg # the compiler driver
      next
    end
    from = File.expand_path(arg, build)
    abort "link input #{arg} not found" unless File.file?(from)
    FileUtils.mkdir_p(File.dirname(File.join(sdk, arg)))
    FileUtils.cp(from, File.join(sdk, arg))
    result << "@SDK@/#{arg}"
    result << "@EXTRA@" if arg == "ocran_main.o"
  end
end
File.write(File.join(sdk, "link.args"), result.join("\n") + "\n")
# mkmf's link checks link with -l<RUBY_SO_NAME>, a DLL Ruby's import
# library; for this static Ruby that is the static library itself.
static_lib = Dir[File.join(sdk, "lib*-static.a")].first or abort "no static libruby in the link inputs"
FileUtils.cp(static_lib, static_lib.sub(/-static\.a\z/, ".a"))

FileUtils.mkdir_p(File.join(sdk, "deps"))
FileUtils.cp_r(File.join(deps, "lib"), File.join(sdk, "deps"))
FileUtils.cp_r(File.join(deps, "include"), File.join(sdk, "deps"))
Dir[File.join(sdk, "deps/lib/{*.la,cmake,engines-3,ossl-modules}")].each { |f| FileUtils.rm_rf(f) }
# pkg-config files (nokogiri finds libxml2 through them): their absolute
# paths become @SDK_DEPS@, filled in by Ocran::NativeSdk when it uses them.
Dir[File.join(sdk, "deps/lib/pkgconfig/*.pc")].each do |pc|
  File.write(pc, File.read(pc).gsub(deps, "@SDK_DEPS@"))
end

# The libraries also built as DLLs (the LGPL ones: GNU libiconv, FreeTDS),
# for `ocran --native-dll`: the DLL and its import library.
FileUtils.mkdir_p(File.join(sdk, "deps/bin"))
dlls = {}
Dir[File.join(deps, "lib", "lib*.dll.a")].sort.each do |import|
  name = File.basename(import)[/\Alib(.+)\.dll\.a\z/, 1]
  dll = Dir[File.join(deps, "bin", "lib#{name}{-*,}.dll")].first or next
  FileUtils.cp(dll, File.join(sdk, "deps/bin"))
  system(result.first.sub(/gcc\z/, "strip"), "--strip-unneeded", File.join(sdk, "deps/bin", File.basename(dll)), exception: true)
  dlls[name] = { "dll" => "deps/bin/#{File.basename(dll)}", "import" => "deps/lib/#{File.basename(import)}" }
end

# What an extension's own libraries (-lsybdb, -lxml2, ...) need in turn, in
# static link order; appended after them (see build_static_ext.rb).
libs = %w[-lexslt -lxslt -lxml2 -lsybdb -lz -liconv -lssl -lcrypto -lyaml -lffi
          -lsecur32 -lcrypt32 -lws2_32 -lbcrypt -lgdi32 -luser32 -ladvapi32]
# Defines the static libraries' headers need, or they declare their API
# dllimport (libxslt, libexslt, libxml2, libyaml).
cppflags = %w[-DLIBXML_STATIC -DLIBXSLT_STATIC -DLIBEXSLT_STATIC -DYAML_DECLARE_STATIC]
File.write(File.join(sdk, "sdk.json"),
           JSON.pretty_generate("toolchain" => "gcc", "libs" => libs, "cppflags" => cppflags, "dlls" => dlls) + "\n")

FileUtils.cp_r(File.join(src, "include"), File.join(sdk, "include"))
arch_include = Dir[File.join(build, ".ext/include/*/ruby/config.h")].first or abort "no ruby/config.h"
arch = File.basename(File.dirname(File.dirname(arch_include)))
FileUtils.cp_r(File.dirname(File.dirname(arch_include)), File.join(sdk, "include", arch))
# Where <arch>-fake.rb points mkmf for ruby/config.h (Ruby's build-tree layout).
FileUtils.mkdir_p(File.join(sdk, ".ext/include"))
FileUtils.cp_r(File.dirname(File.dirname(arch_include)), File.join(sdk, ".ext/include", arch))

# rbconfig.rb names the dependency directory of this build; point it at the
# SDK's copy, wherever the SDK ends up.
rbconfig = File.read(File.join(build, "rbconfig.rb"))
rbconfig = rbconfig.gsub(deps, '#{File.expand_path("deps", __dir__)}')
File.write(File.join(sdk, "rbconfig.rb"), rbconfig)
# <arch>-fake.rb loads tool/fake.rb from the Ruby source tree.
FileUtils.mkdir_p(File.join(sdk, "tool"))
FileUtils.cp(File.join(src, "tool/fake.rb"), File.join(sdk, "tool/fake.rb"))
fake = File.read(File.join(build, "#{arch}-fake.rb"))
fake = fake.sub(/^srcdir = .*$/, "srcdir = builddir") or abort "unexpected #{arch}-fake.rb"
File.write(File.join(sdk, "#{arch}-fake.rb"), fake)

FileUtils.mkdir_p(File.join(sdk, "exts"))
ext_files.each do |line_file|
  feature, init, archive, libs = File.read(line_file).strip.split(" ", 4)
  name = feature.tr("/", "_")
  FileUtils.cp(archive, File.join(sdk, "exts", "#{name}.a"))
  File.write(File.join(sdk, "exts", "#{name}.line"), [feature, init, "@SDK@/exts/#{name}.a", libs].join(" ") + "\n")
end
puts "#{sdk}: #{result.count { _1.start_with?("@SDK@/") }} link inputs, #{ext_files.size} gem extensions"
