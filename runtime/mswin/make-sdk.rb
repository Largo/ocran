# The mswin counterpart of runtime/make-sdk.rb: captures what is needed to
# link the runtime (again, with more C extensions) into an SDK directory.
# Run by the Ruby build-ruby.cmd installed, inside a vcvars64 environment:
#
#   ruby runtime\mswin\make-sdk.rb BUILD_DIR SRC_DIR DEPS_DIR SDK_DIR [EXT_LINE_FILE...]
#
# DEPS_DIR is vcpkg's x64-windows-static tree. Then link the runtime with
#   ruby runtime\link-runtime.rb SDK_DIR ARCH ocran-runtime.exe
require "fileutils"
require "rbconfig"
require "tmpdir"

build, src, deps, sdk, *ext_files = ARGV.map { |a| File.expand_path(a.tr("\\", "/")) }
abort "usage: make-sdk.rb BUILD_DIR SRC_DIR DEPS_DIR SDK_DIR [EXT_LINE_FILE...]" unless sdk
recipes = File.expand_path("..", __dir__)
FileUtils.rm_rf(sdk)
FileUtils.mkdir_p(sdk)

def copy(from, to)
  abort "#{from} not found" unless File.file?(from)
  FileUtils.mkdir_p(File.dirname(to))
  FileUtils.cp(from, to)
end

# Link inputs exactly as Ruby's own makefiles list them (exts.mk).
mk = File.read(File.join(build, "exts.mk")).gsub(/\\\r?\n/, " ")
var = ->(name) { mk[/^#{name} = (.*)$/, 1].to_s.split }
arch_hdr = Dir[File.join(build, ".ext/include/*/ruby/config.h")].first or abort "no ruby/config.h"
arch = File.basename(File.dirname(File.dirname(arch_hdr)))
librubya = File.basename(Dir[File.join(build, "*-static.lib")].first || abort("no libruby static library"))

FileUtils.cp_r(File.join(src, "include"), File.join(sdk, "include"))
FileUtils.cp_r(File.dirname(File.dirname(arch_hdr)), File.join(sdk, "include", arch))

# ocran_main.obj, with stage0.rb compiled in, built with the runtime's flags.
Dir.mktmpdir do |tmp|
  system(RbConfig.ruby, File.join(recipes, "gen-stage0-header.rb"), File.join(recipes, "stage0.rb"),
         File.join(tmp, "stage0.h"), exception: true)
  system("cl", "-nologo", "-MT", "-O2", "-I#{tmp}", "-I#{File.join(sdk, "include", arch)}",
         "-I#{File.join(sdk, "include")}", "-c", File.join(recipes, "ocran_main.c"),
         "-Fo#{File.join(sdk, "ocran_main.obj")}", exception: true)
end

inputs = (var.("EXTOBJS") + %w[enc/encinit.obj enc/libenc.lib enc/libtrans.lib] + [librubya, "ruby.res"])
inputs.each { |rel| copy(File.join(build, rel), File.join(sdk, rel)) }
FileUtils.mkdir_p(File.join(sdk, "deps"))
%w[lib include].each { |d| FileUtils.cp_r(File.join(deps, d), File.join(sdk, "deps")) }
FileUtils.rm_rf(File.join(sdk, "deps/lib/pkgconfig"))
# vcpkg names its static zlib zs.lib; Ruby's zlib extconf looks for zlib.lib.
FileUtils.cp(File.join(sdk, "deps/lib/zs.lib"), File.join(sdk, "deps/lib/zlib.lib")) if File.file?(File.join(sdk, "deps/lib/zs.lib"))

libs = var.("EXTLIBS") + %w[user32.lib advapi32.lib shell32.lib ws2_32.lib iphlpapi.lib imagehlp.lib shlwapi.lib bcrypt.lib]
args = ["cl", "-nologo", "-MT", "@SDK@/ocran_main.obj", "@EXTRA@",
        *inputs.map { |rel| "@SDK@/#{rel}" }, *libs.uniq, "-Fe@OUTPUT@",
        "-link", "-incremental:no", "-opt:ref", "-opt:icf", "-stack:0x400000", "-subsystem:console",
        "-libpath:@SDK@/deps/lib"]
File.write(File.join(sdk, "link.args"), args.join("\n") + "\n")
File.write(File.join(sdk, "sdk.json"), %({"toolchain": "msvc"}\n))

# rbconfig.rb names the dependency directories of this build; point them at
# the SDK's copy, wherever the SDK ends up. extconf.rb runs against it.
rbconfig = File.read(File.join(build, "rbconfig.rb"))
[deps, File.expand_path("../compat", deps.sub(%r{/installed/[^/]+\z}, "/installed"))].each do |dir|
  rbconfig = rbconfig.gsub(dir, '#{File.expand_path("deps", __dir__)}')
end
File.write(File.join(sdk, "rbconfig.rb"), rbconfig)

FileUtils.mkdir_p(File.join(sdk, "exts"))
ext_files.each do |line_file|
  feature, init, archive, ext_libs = File.read(line_file).strip.split(" ", 4)
  name = feature.tr("/", "_")
  FileUtils.cp(archive, File.join(sdk, "exts", "#{name}.lib"))
  File.write(File.join(sdk, "exts", "#{name}.line"), [feature, init, "@SDK@/exts/#{name}.lib", ext_libs].join(" ") + "\n")
end
puts "#{sdk}: #{inputs.size + 1} link inputs, #{ext_files.size} gem extensions (#{arch})"
