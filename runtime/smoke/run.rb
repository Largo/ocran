# Packages the smoke-test applications with a static runtime and runs them:
#
#   ruby runtime/smoke/run.rb RUNTIME_DIR [OUT_DIR]
#
# Exits non-zero when an executable cannot be built or does not behave.
# HTTPS is checked only when OCRAN_SMOKE_NETWORK=1, a gem with a C
# extension (nokogiri, installed for the build host's Ruby) only when
# OCRAN_SMOKE_GEMS=1. OCRAN_SMOKE_PREBUILT=1 runs the executables already in
# OUT_DIR (packaged on another host) instead of building them.
#
# The executables run with a minimal PATH and without Ruby's environment
# variables: they must need nothing from the machine.
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
prebuilt = ENV["OCRAN_SMOKE_PREBUILT"] == "1"
abort "OCRAN_SMOKE_PREBUILT=1 needs a runtime for #{host}" if prebuilt && !runnable
puts "runtime for #{target}; #{prebuilt ? "running prebuilt executables" : runnable ? "building and running" : "building only (not runnable on #{host})"}"

system_dirs = if host == "windows"
                root = ENV.fetch("SystemRoot", "C:\\Windows")
                "#{root}\\System32;#{root}"
              else
                "/usr/bin:/bin"
              end
bare_env = { "PATH" => system_dirs, "RUBYOPT" => nil, "RUBYLIB" => nil, "GEM_HOME" => nil, "GEM_PATH" => nil,
             "BUNDLE_GEMFILE" => nil, "SSL_CERT_FILE" => nil, "SSL_CERT_DIR" => nil }
run = ->(exe, *args) { Open3.capture3(bare_env, exe, *args) }

ocran = lambda do |*args, output:|
  if prebuilt
    exists = !Dir["#{output}{,.exe}"].empty?
    failures << "#{File.basename(output)} was not found in #{File.dirname(output)}" unless exists
    next exists
  end
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
  stdout, stderr, status = run.(exe, "one", "two words", "--verbose")
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
    stdout, stderr, = run.(exe)
    failures << "smoke-https: #{stderr}" unless stderr.empty?
    check.("smoke-https", stdout, { "https" => "200", "self_signed" => "rejected" })
  end
end

if ENV["OCRAN_SMOKE_GEMS"] == "1"
  gems = File.join(out, "smoke-gems")
  if ocran.call("gems.rb", output: gems) && runnable
    exe = Dir["#{gems}{,.exe}"].first
    stdout, stderr, status = run.(exe)
    failures << "smoke-gems exited #{status.exitstatus}: #{stderr}" unless status.success?
    check.("smoke-gems", stdout.force_encoding(Encoding::UTF_8), {
           "html" => "h\u00e9llo", "xpath" => "1,2", "xslt" => "sum=3", "from_disk" => "0" })
  end
end

if failures.empty?
  puts "smoke tests passed"
else
  warn failures.join("\n\n")
  exit 1
end
