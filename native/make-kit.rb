# Captures everything the runtime link needs into a self-contained "kit"
# directory, so the runtime can be re-linked later - with gem C extensions
# added - without the Ruby build tree:
#
#   ruby native/make-kit.rb RUBY_BUILD_DIR DEPS_DIR KIT_DIR
#
# Asks Ruby's own makefile for the ruby.exe link command (dry run, with
# ocran_main.o as the main object), copies every input file into the kit
# and writes the command to KIT_DIR/link.args, one argument per line, with
# the kit directory as @KIT@ and the place for extra objects as @EXTRA@.
require "fileutils"
require "shellwords"

build, deps, kit = ARGV.map { |a| File.expand_path(a) }
abort "usage: make-kit.rb RUBY_BUILD_DIR DEPS_DIR KIT_DIR" unless kit

cmd = Dir.chdir(build) do
  out = IO.popen(["make", "-f", "exts.mk", "-n", "RUBY_EXP=", "MAINOBJ=ocran_main.o",
                  "EXTENCS=enc/encinit.o enc/libenc.a enc/libtrans.a", "ruby.exe",
                  err: File::NULL], &:read)
  out.lines.grep(/-o ruby\.exe\s*$/).last or abort "no link command for ruby.exe in dry run"
end
args = Shellwords.split(cmd)

FileUtils.rm_rf(kit)
FileUtils.mkdir_p(kit)
result = []
skip_next = false
args.each_with_index do |arg, i|
  next skip_next = false if skip_next
  case arg
  when "-o"
    skip_next = true
  when /\A-L(.*)\z/
    dir = File.expand_path($1, build)
    result << (dir == build ? "-L@KIT@" : dir == File.join(deps, "lib") ? "-L@KIT@/deps" : arg)
  when /\A-/
    result << arg
  else
    if i.zero?
      result << arg # the compiler driver
      next
    end
    src = File.expand_path(arg, build)
    abort "link input #{arg} not found" unless File.file?(src)
    FileUtils.mkdir_p(File.dirname(File.join(kit, arg)))
    FileUtils.cp(src, File.join(kit, arg))
    result << "@KIT@/#{arg}"
    result << "@EXTRA@" if arg == "ocran_main.o"
  end
end
FileUtils.mkdir_p(File.join(kit, "deps"))
Dir[File.join(deps, "lib", "*.a")].each { |a| FileUtils.cp(a, File.join(kit, "deps")) }
File.write(File.join(kit, "link.args"), result.join("\n") + "\n")
puts "#{kit}: #{result.count { _1.start_with?("@KIT@/") }} link inputs"
