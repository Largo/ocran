# Packages the smoke-test applications with a static runtime and runs them:
#
#   ruby runtime/smoke/run.rb RUNTIME_DIR [OUT_DIR]
#
# Exits non-zero when an executable cannot be built or does not behave.
# HTTPS is checked only when OCRAN_SMOKE_NETWORK=1.
require "open3"
require "rbconfig"
require "fileutils"

runtime, out = ARGV
abort "usage: run.rb RUNTIME_DIR [OUT_DIR]" unless runtime
here = __dir__
repo = File.expand_path("../..", here)
out = File.expand_path(out || "smoke-out")
FileUtils.mkdir_p(out)
failures = []
require "json"
target = JSON.parse(File.read(File.join(runtime, "runtime.json"))).fetch("os", "windows")
host = case RbConfig::CONFIG["host_os"]
       when /mingw|mswin/ then "windows"
       when /darwin/ then "macos"
       else "linux"
       end
runnable = target == host
puts "runtime for #{target}; #{runnable ? "building and running" : "building only (not runnable on #{host})"}"

ocran = lambda do |*args, output:|
  cmd = [RbConfig.ruby, "-I", File.join(repo, "lib"), File.join(repo, "exe/ocran"),
         "--static-runtime", File.expand_path(runtime), "--output", output, *args]
  log, status = Open3.capture2e(*cmd, chdir: here)
  File.write("#{output}.build.log", log)
  status.success? or failures << "building #{File.basename(output)} failed:\n#{log.lines.last(15).join}"
  status.success?
end

check = lambda do |name, output, expected|
  values = output.lines.to_h { |l| l.chomp.split("=", 2) }
  expected.each do |key, want|
    got = values[key]
    failures << "#{name}: #{key}=#{got.inspect}, expected #{want.inspect}" unless want === got
  end
  puts "#{name}: #{output.lines.size} lines checked"
end

app = File.join(out, "smoke-app")
if ocran.call("app.rb", "helper.rb", "lazy.rb", "data.txt", output: app) && runnable
  exe = Dir["#{app}{,.exe}"].first
  stdout, stderr, status = Open3.capture3(exe, "one", "two words", "--verbose")
  failures << "smoke-app exited #{status.exitstatus}, expected 7: #{stderr}" unless status.exitstatus == 7
  check.("smoke-app", stdout, {
         "file_in_exe" => "true", "main" => "true", "helper" => "hello from helper.rb", "autoload" => "lazy",
         "json" => '[1,{"a":2}]', "yaml" => "3", "sha256" => "ba7816bf8f01cfea", "zlib" => "891568578",
         "data" => "payload", "glob" => "app.rb,helper.rb,lazy.rb", "argv" => "one|two words|--verbose",
         "DATA" => "data section", "mtime" => "true", "from_disk" => "0" })
end

if ENV["OCRAN_SMOKE_NETWORK"] == "1"
  https = File.join(out, "smoke-https")
  if ocran.call("https.rb", output: https) && runnable
    exe = Dir["#{https}{,.exe}"].first
    stdout, stderr, = Open3.capture3(exe)
    failures << "smoke-https: #{stderr}" unless stderr.empty?
    check.("smoke-https", stdout, { "https" => "200", "self_signed" => "rejected" })
  end
end

if failures.empty?
  puts "smoke tests passed"
else
  warn failures.join("\n\n")
  exit 1
end
