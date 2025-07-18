# frozen_string_literal: true

require_relative "lib/ocran/version"

Gem::Specification.new do |spec|
  spec.name = "ocran"
  spec.version = Ocran::VERSION
  spec.authors = ["Andi Idogawa", "Lars Christensen"]
  spec.email = ["andi@idogawa.com"]

  spec.licenses = ["MIT"]

  spec.summary = "OCRAN (One-Click Ruby Application Next) builds Windows executables from Ruby source code."
  spec.description = "OCRAN (One-Click Ruby Application Next) builds Windows executables from Ruby source code. 
  The executable is a self-extracting, self-running executable that contains the Ruby interpreter, your source code and any additionally needed ruby libraries or DLL.
  
  This is a fork of OCRA that is compatible with ruby version after 3.2.
  Migration guide: make sure to write ocran instead of ocra in your code. For instance: OCRAN_EXECUTABLE

  usage: 
    ocra helloworld.rb
    helloworld.exe

  See readme at https://github.com/largo/ocran
  Report problems in the github issues. Contributions welcome.
  This gem contains executables. We plan to build them on github actions for security.
  "
  spec.homepage = "https://github.com/largo/ocran"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/largo/ocran"
  spec.metadata["changelog_uri"] = "https://github.com/largo/ocran/CHANGELOG.txt"

  spec.files = Dir.glob("{exe,lib,share}/**/*") +
               %w[README.md LICENSE.txt CHANGELOG.txt]
  spec.bindir = "exe"
  spec.executables = Dir.glob("exe/*").map { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "fiddle", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
