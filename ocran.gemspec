# frozen_string_literal: true

require_relative "lib/ocran/version"

Gem::Specification.new do |spec|
  spec.name = "ocran"
  spec.version = Ocran::VERSION
  spec.authors = ["Andi Idogawa", "shinokaro", "Lars Christensen"]
  spec.email = ["andi@idogawa.com"]

  spec.licenses = ["MIT"]

  spec.summary = "OCRAN (One-Click Ruby Application Next) packages Ruby applications for distribution on Windows, Linux, and macOS."
  spec.description = <<~DESC
    OCRAN (One-Click Ruby Application Next) packages Ruby applications for
    distribution. It bundles your script, the Ruby interpreter, gems, and native
    libraries into a self-contained artifact that runs without requiring Ruby to
    be installed on the target machine.

    Three output formats are supported on all platforms:
    - Self-extracting executable (.exe on Windows, native binary on Linux/macOS)
    - Directory with a launch script (--output-dir)
    - Zip archive with a launch script (--output-zip)

    This is a fork of OCRA maintained for Ruby 3.2+ compatibility.
    Migration guide: replace OCRA_EXECUTABLE with OCRAN_EXECUTABLE in your code.

    Usage:
      ocran helloworld.rb          # builds helloworld.exe / helloworld
      ocran --output-dir out/ app.rb
      ocran --output-zip app.zip app.rb

    See readme at https://github.com/largo/ocran
    Report problems at https://github.com/largo/ocran/issues
  DESC
  spec.homepage = "https://github.com/largo/ocran"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/largo/ocran"
  spec.metadata["changelog_uri"] = "https://github.com/largo/ocran/CHANGELOG.txt"

  # Each platform ships only its own compiled stub binary.
  # gem install ocran automatically selects the right gem for the current platform.
  spec.platform = Gem::Platform::CURRENT

  spec.files = Dir.glob("{exe,lib,share}/**/*") +
               %w[README.md LICENSE.txt CHANGELOG.txt]
  spec.bindir = "exe"
  spec.executables = Dir.glob("exe/*").map { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "fiddle", "~> 1.0"
end
