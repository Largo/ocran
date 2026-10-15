# frozen_string_literal: true
require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/ocran/env_hook"
require_relative "../lib/ocran/build_helper"

# Unit tests for the RubyGems startup hook (rubygems/defaults/operating_system.rb)
# that gives a bare bin/ruby of a package the launch script's environment.
# The generated hook is run by this Ruby, from a package layout in a
# temporary directory.
class TestEnvHook < Minitest::Test
  WINDOWS = Gem.win_platform?
  SITE = "lib/ruby/site_ruby/9.9.0"
  STDLIB = "lib/ruby/9.9.0"
  # The variables the hook may touch, cleared for the child process.
  VARIABLES = %w[GEM_HOME GEM_PATH RUBYLIB SSL_CERT_FILE SSL_CERT_DIR BUNDLER_SETUP BUNDLE_GEMFILE RUBYOPT].freeze

  ENV_AT_BUILD = {
    "SSL_CERT_FILE" => "|/lib/ruby/9.9.0/etc/ssl/cert.pem",
    "SSL_CERT_DIR" => "|/lib/ruby/9.9.0/etc/ssl/certs",
    "RUBYOPT" => "",
    "BUNDLER_SETUP" => "|/no_bundler_setup.rb",
    "BUNDLE_GEMFILE" => "",
    "RUBYLIB" => "|/src/lib",
    "GEM_HOME" => "|/gems",
    "GEM_PATH" => ["|/gems", "|/lib/ruby/gems/9.9.0"].join(File::PATH_SEPARATOR),
  }.freeze

  # Writes the hook into +pkg+ at the packed sitelibdir, plus (with
  # +original+) a stand-in for the operating_system.rb a Ruby installation
  # ships, in its stdlib directory.
  def build_package(pkg, original: true)
    hook = File.join(pkg, SITE, Ocran::EnvHook::FEATURE)
    FileUtils.mkdir_p(File.dirname(hook))
    depth = File.dirname(File.join(SITE, Ocran::EnvHook::FEATURE)).split("/").size
    File.write(hook, Ocran::EnvHook.source(ENV_AT_BUILD, depth))
    if original
      file = File.join(pkg, STDLIB, Ocran::EnvHook::FEATURE)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "$ocran_original = ENV['GEM_HOME']\n")
    end
    FileUtils.mkdir_p(File.join(pkg, "src", "lib"))
    hook
  end

  # Starts this Ruby the way a bare packed bin/ruby starts: RubyGems
  # requires the hook from the first load path entry, the stdlib dir comes
  # after it. The load path is only the package's, so that an
  # operating_system.rb of this Ruby's installation is not found.
  # Returns what the child saw.
  def run_hook(pkg, env = {})
    # Cleared again inside the child: a Ruby can set some of them while it
    # starts (setup-ruby's mswin build sets SSL_CERT_FILE), and the hook
    # rightly keeps a value that is already there.
    unset = VARIABLES - env.keys
    script = <<~RUBY
      require "json"
      #{unset.inspect}.each { |name| ENV.delete(name) }
      $LOAD_PATH.replace(#{[File.join(pkg, SITE), File.join(pkg, STDLIB)].inspect})
      require "rubygems/defaults/operating_system"
      puts JSON.generate(env: ENV.to_h.slice(*#{VARIABLES.inspect}), original: $ocran_original,
                         load_path: $LOAD_PATH.first(3), features: $LOADED_FEATURES.grep(/operating_system/))
    RUBY
    child_env = VARIABLES.to_h { |name| [name, nil] }.merge(env)
    out, status = Open3.capture2e(child_env, RbConfig.ruby, "--disable-gems", "-e", script)
    assert status.success?, "hook failed: #{out}"
    JSON.parse(out.lines.last)
  end

  # The launch script empties BUNDLE_GEMFILE (and BUNDLE_LOCKFILE) whatever
  # the parent set, so that the packaged Gemfile is used; so does the hook.
  def test_variables_the_launch_script_empties_are_removed
    Dir.mktmpdir do |dir|
      pkg = File.join(dir, "pkg")
      build_package(pkg)
      env = run_hook(pkg, "BUNDLE_GEMFILE" => "/parent/Gemfile")
      refute env["env"].key?("BUNDLE_GEMFILE"), "an inherited BUNDLE_GEMFILE was kept"
    end
  end

  # How the launch script renders a packed path under the package root.
  def packed(root, rel)
    path = File.join(root, rel)
    WINDOWS ? path.tr("/", "\\") : path
  end

  def test_sets_unset_variables_relative_to_the_package
    Dir.mktmpdir do |tmp|
      pkg = File.join(File.realpath(tmp), "moved package")
      build_package(pkg)
      result = run_hook(pkg)
      env = result["env"]

      assert_equal packed(pkg, "gems"), env["GEM_HOME"]
      assert_equal [packed(pkg, "gems"), packed(pkg, "lib/ruby/gems/9.9.0")].join(File::PATH_SEPARATOR), env["GEM_PATH"]
      assert_equal packed(pkg, "lib/ruby/9.9.0/etc/ssl/cert.pem"), env["SSL_CERT_FILE"]
      assert_equal packed(pkg, "lib/ruby/9.9.0/etc/ssl/certs"), env["SSL_CERT_DIR"]
      assert_equal packed(pkg, "no_bundler_setup.rb"), env["BUNDLER_SETUP"]
      assert_equal packed(pkg, "src/lib"), env["RUBYLIB"]
      # Empty values mean "unset" to Ruby and Bundler; the batch script's
      # `set "X="` even removes the variable.
      refute env.key?("RUBYOPT")
      refute env.key?("BUNDLE_GEMFILE")
      # RUBYLIB is read before the hook runs, so the hook also puts its
      # directories on the load path, where Ruby would have: in front of
      # the directory the hook was found in.
      assert_equal File.join(pkg, "src/lib"), result["load_path"][0]
      assert_equal File.join(pkg, SITE), result["load_path"][1]
    end
  end

  def test_keeps_variables_that_are_set
    Dir.mktmpdir do |tmp|
      pkg = File.join(tmp, "pkg")
      build_package(pkg)
      env = run_hook(pkg, "GEM_HOME" => "/explicit/gems", "SSL_CERT_FILE" => "/explicit/cert.pem",
                          "RUBYLIB" => "")["env"]

      assert_equal "/explicit/gems", env["GEM_HOME"]
      assert_equal "/explicit/cert.pem", env["SSL_CERT_FILE"]
      assert_equal "", env["RUBYLIB"]
      assert env["GEM_PATH"], "an unset variable is still set"
    end
  end

  # The Ruby installation's own operating_system.rb (RubyInstaller sets
  # up its DLL search paths in it) is loaded after the variables are set,
  # as it would be under the launch script.
  def test_chains_to_the_original_hook
    Dir.mktmpdir do |tmp|
      pkg = File.join(File.realpath(tmp), "pkg")
      hook = build_package(pkg)
      result = run_hook(pkg)

      assert_equal packed(pkg, "gems"), result["original"]
      # Each loaded once (the original finishes loading first).
      assert_equal [hook, File.join(pkg, STDLIB, Ocran::EnvHook::FEATURE)].sort, result["features"].sort
    end
  end

  def test_without_an_original_hook
    Dir.mktmpdir do |tmp|
      pkg = File.join(tmp, "pkg")
      build_package(pkg, original: false)
      result = run_hook(pkg)

      assert_nil result["original"]
      assert_equal 1, result["features"].size
      assert result["env"]["GEM_HOME"]
    end
  end

  # Direction#construct generates the hook from what it exported, through
  # whatever builder it drives.
  def test_build_helper_records_exports
    builder = Class.new {
      attr_reader :exports

      def export(name, value) = (@exports ||= []) << [name, value]
    }.new.extend(Ocran::BuildHelper)
    builder.export("GEM_HOME", "|/gems")
    builder.set_env_path("GEM_PATH", "gems", "lib/ruby/gems/9.9.0")

    assert_equal({ "GEM_HOME" => "|/gems",
                   "GEM_PATH" => ["|/gems", "|/lib/ruby/gems/9.9.0"].join(File::PATH_SEPARATOR) },
                 builder.exported_env)
    assert_equal 2, builder.exports.size, "exports still reach the builder"
  end
end
