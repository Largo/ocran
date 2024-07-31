# frozen_string_literal: true

module Ocran
  module BuildConstants
    # Alias for the temporary directory where files are extracted.
    EXTRACT_ROOT = Pathname.new("|")
    # Directory for source files in temporary directory.
    SRCDIR = Pathname.new("src")
    # Directory for Ruby binaries in temporary directory.
    BINDIR = Pathname.new("bin")
    # Directory for gem files in temporary directory.
    GEMDIR = Pathname.new("gems")
    # Directory for Ruby library in temporary directory.
    LIBDIR = Pathname.new("lib")
  end
end
