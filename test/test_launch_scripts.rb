# frozen_string_literal: true
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/ocran/dir_builder"
require_relative "../lib/ocran/launcher_batch_builder"

# Unit tests for the launch scripts written for --output-dir/--output-zip
# (DirBuilder) and Inno Setup (LauncherBatchBuilder). Build-time values must
# reach the application literally, whatever shell metacharacters they hold.
class TestLaunchScripts < Minitest::Test
  # Characters that the shell or cmd.exe would otherwise interpret.
  NASTY_VALUE = %q{cost $5 `x` $(echo pwned) 50% & | it's %PATH%}
  # A directory the app may be unpacked to.
  NASTY_DIR = "R&D 50% $HOME it's"

  SHOW_ARGS = <<~RUBY
    puts ENV["NASTY"], ENV["ROOTED"], *ARGV
  RUBY

  # Builds a directory in +parent+ whose launch script runs this Ruby with a
  # packed script that prints the exported values and its arguments.
  def build_dir(parent)
    script_file = File.join(parent, "show.rb")
    File.write(script_file, SHOW_ARGS)
    out = File.join(parent, NASTY_DIR)
    Ocran::DirBuilder.new(out) do |b|
      b.cp(script_file, "src/show.rb")
      b.export("NASTY", NASTY_VALUE)
      b.export("ROOTED", "|/lib")
      b.exec(RbConfig.ruby, "src/show.rb", NASTY_VALUE, "")
    end
    out
  end

  def run_launch_script(*cmd, chdir: Dir.pwd)
    out, status = Open3.capture2({ "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil }, *cmd, "extra arg", chdir: chdir)
    assert status.success?, "launch script failed: #{out}"
    out.lines(chomp: true)
  end

  def test_shell_script_passes_values_literally
    skip "shell launch script is POSIX only" if Gem.win_platform?

    Dir.mktmpdir do |tmp|
      out = build_dir(tmp)
      lines = run_launch_script("sh", File.join(out, "show.sh"))
      assert_equal [NASTY_VALUE, File.join(File.realpath(out), "lib"), NASTY_VALUE, "", "extra arg"], lines
    end
  end

  def test_batch_script_passes_values_literally
    skip "batch launch script is Windows only" unless Gem.win_platform?

    Dir.mktmpdir do |tmp|
      out = build_dir(tmp)
      # Run it by relative path: cmd /c would mangle a quoted path holding
      # "&", while %~dp0 inside the script still sees the full path.
      lines = run_launch_script("cmd", "/c", "show.bat", chdir: out)
      assert_equal NASTY_VALUE, lines[0]
      assert_equal File.join(out, "lib").tr("/", "\\"), lines[1]
      assert_equal [NASTY_VALUE, "", "extra arg"], lines[2..]
    end
  end

  # The batch script can only run on Windows, but its text is checked
  # everywhere.
  def test_batch_script_text_is_escaped
    Dir.mktmpdir do |tmp|
      builder = Ocran::DirBuilder.new(tmp) do |b|
        b.export("ROOTED", "|/lib/50%")
        b.exec("bin/ruby.exe", "src/app.rb", "a & b")
      end
      builder.send(:write_batch_script)
      bat = File.read(File.join(tmp, "app.bat")).split("\r\n")
      assert_equal 'set "SCRIPT_DIR=%~dp0"', bat[1]
      assert_equal 'set "ROOTED=%SCRIPT_DIR%lib\50%%"', bat[2]
      assert_equal '"%SCRIPT_DIR%bin\ruby.exe" "%SCRIPT_DIR%src\app.rb" "a & b" %*', bat[3]
    end
  end

  def test_inno_setup_launcher_escapes_percent
    builder = Ocran::LauncherBatchBuilder.new(title: "100% app")
    builder.export("ROOTED", "|/lib/50%")
    builder.exec("bin/ruby.exe", "src/app.rb", "50% off")
    bat = File.read(builder.build).lines(chomp: true)
    assert_equal 'set "ROOTED=%~dp0lib/50%%"', bat[1]
    assert_equal 'set "OCRAN_EXECUTABLE=%~f0"', bat[2]
    assert_equal 'start "100%% app" "%~dp0bin/ruby.exe" "%~dp0src/app.rb" "50%% off" %*', bat[3]
  end
end
