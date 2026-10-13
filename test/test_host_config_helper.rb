# frozen_string_literal: true
require "minitest/autorun"
require_relative "../lib/ocran/host_config_helper"

# Unit tests for how HostConfigHelper reads the host's RbConfig.
class TestHostConfigHelper < Minitest::Test
  KEYS = %w[ENABLE_SHARED LIBRUBY_SO LIBRUBY_ALIASES].freeze

  def with_config(values)
    saved = RbConfig::CONFIG.slice(*KEYS)
    KEYS.each { |key| RbConfig::CONFIG.delete(key) }
    RbConfig::CONFIG.update(values)
    yield
  ensure
    KEYS.each { |key| RbConfig::CONFIG.delete(key) }
    RbConfig::CONFIG.update(saved)
  end

  def test_shared_libruby
    with_config("ENABLE_SHARED" => "yes", "LIBRUBY_SO" => "libruby.so.4.0.6",
                "LIBRUBY_ALIASES" => "libruby.so.4.0 libruby.so") do
      assert_equal Pathname("libruby.so.4.0.6"), Ocran::HostConfigHelper.libruby_so
      assert_equal [Pathname("libruby.so.4.0"), Pathname("libruby.so")],
                   Ocran::HostConfigHelper.libruby_aliases
    end
  end

  # A Ruby built without --enable-shared reports LIBRUBY_SO and
  # LIBRUBY_ALIASES although only libruby-static.a exists, and packaging
  # aborted because the shared library was missing.
  def test_static_libruby
    with_config("ENABLE_SHARED" => "no", "LIBRUBY_SO" => "libruby.so.4.0.6",
                "LIBRUBY_ALIASES" => "libruby.so") do
      assert_nil Ocran::HostConfigHelper.libruby_so
      assert_empty Ocran::HostConfigHelper.libruby_aliases
    end
  end

  def test_empty_libruby_so
    with_config("ENABLE_SHARED" => "yes", "LIBRUBY_SO" => "", "LIBRUBY_ALIASES" => "") do
      assert_nil Ocran::HostConfigHelper.libruby_so
      assert_empty Ocran::HostConfigHelper.libruby_aliases
    end
  end
end
