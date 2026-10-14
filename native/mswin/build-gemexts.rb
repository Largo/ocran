# Builds the bundled gems' C extensions as static libraries for the mswin
# runtime (Ruby's own build links them only as DLLs). Run by the Ruby that
# build-ruby.cmd installed, inside a vcvars64 environment:
#
#   ROOT\stage\bin\ruby.exe native\mswin\build-gemexts.rb ROOT
#
# Writes ROOT\exts\<name>.line for link-runtime.rb.
require "fileutils"

root = (ARGV[0] or abort "usage: build-gemexts.rb ROOT").tr("\\", "/")
deps = "#{root}/deps/installed/x64-windows-static"
helper = File.expand_path("../build-static-ext.rb", __dir__)
FileUtils.rm_rf("#{root}/exts")
FileUtils.mkdir_p("#{root}/exts")
%w[fiddle bigdecimal racc/cparse win32ole].each do |ext|
  gem = ext.split("/").first
  gemdir = Dir["#{root}/src/.bundle/gems/#{gem}-[0-9]*"].first or abort "no #{gem} in #{root}/src/.bundle/gems"
  name = ext.tr("/", "_")
  log = "#{root}/gemext-#{name}.log"
  ok = system(RbConfig.ruby, "--disable=gems", helper, "#{root}/build", "#{root}/src",
              "#{gemdir}/ext/#{ext}", "#{root}/gemext/#{name}", "--with-opt-dir=#{deps}",
              out: log, err: [:child, :out])
  abort "#{ext} failed, see #{log}" unless ok
  line = File.readlines(log).last
  File.write("#{root}/exts/#{name}.line", line)
  puts line
end
