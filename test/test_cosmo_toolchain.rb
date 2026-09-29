# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/ocran/cosmo_toolchain"

# Unit tests for Ocran::CosmoToolchain that need no cosmopolitan Ruby: a
# shell script stands in for the payload interpreter.
class TestCosmoToolchain < Minitest::Test
  # Variables `bundle exec` leaves in the environment of the build.
  BUNDLE_ENV = {
    "BUNDLER_SETUP" => "/build/host/bundler/setup",
    "BUNDLE_GEMFILE" => "/build/host/Gemfile",
    "BUNDLE_LOCKFILE" => "/build/host/Gemfile.lock",
    "RUBYOPT" => "-rbundler/setup",
    "GEM_HOME" => "/build/host/gems",
  }.freeze

  def setup
    skip "the payload is run through /bin/sh on POSIX build hosts only" if Gem.win_platform?
  end

  def with_env(env)
    saved = env.keys.to_h { |name| [name, ENV[name]] }
    env.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
  end

  # A stand-in payload that, like a real interpreter asked to set up the
  # build host's bundle, fails when it sees any of it. Otherwise it answers
  # every feature (the arguments after "-e script") as resolvable.
  def fake_payload(dir)
    path = File.join(dir, "ruby.com")
    File.write(path, <<~SH)
      for name in #{BUNDLE_ENV.keys.join(" ")}; do
        eval "value=\\${$name}"
        [ -n "$value" ] && { echo "$name is set" >&2; exit 1; }
      done
      shift 2
      for feature in "$@"; do echo "$feature"; done
    SH
    path
  end

  # The cache entry is used as soon as it exists, so it is created by a
  # rename, complete and executable, with nothing left beside it.
  def test_compiled_stub_is_cached_atomically
    Dir.mktmpdir do |dir|
      stub = File.join(dir, "stub")
      File.write(stub, "APE")
      cached = File.join(dir, "cache", "ocran", "stub-0123")
      Ocran::CosmoToolchain.install_cached(stub, cached)

      assert_equal "APE", File.read(cached)
      assert File.executable?(cached)
      assert_equal ["stub-0123"], Dir.children(File.dirname(cached))
    end
  end

  # Under `bundle exec` the feature probe inherited BUNDLER_SETUP and
  # BUNDLE_GEMFILE, so the payload failed and every native gem it provides
  # was reported as incompatible.
  def test_feature_probe_runs_outside_the_build_bundle
    Dir.mktmpdir do |dir|
      ruby = fake_payload(dir)
      with_env(BUNDLE_ENV) do
        assert_equal %w[cgi pathname], Ocran::CosmoToolchain.resolvable_features(ruby, %w[cgi pathname])
      end
    end
  end
end
