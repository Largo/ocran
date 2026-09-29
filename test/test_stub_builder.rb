# frozen_string_literal: true
require "minitest/autorun"
require "timeout"
require "tmpdir"
require_relative "../lib/ocran/stub_builder"

# Unit tests for Ocran::StubBuilder that need a built stub but do not run
# the packed executable.
class TestStubBuilder < Minitest::Test
  # An error while writing a compressed payload used to leave the LZMA
  # compressor waiting for more input, so the build hung instead of failing.
  def test_error_in_compressed_build_is_raised
    skip "no LZMA compressor available" unless Ocran::StubBuilder::LZMA_CMD
    skip "stub not built (run rake build)" unless File.exist?(Ocran::StubBuilder::STUB_PATH)

    Dir.mktmpdir do |dir|
      error = Timeout.timeout(60) do
        assert_raises(RuntimeError) do
          Ocran::StubBuilder.new(File.join(dir, "app"), enable_compression: true) do
            raise "payload failed"
          end
        end
      end
      assert_equal "payload failed", error.message
    end
  end
end
