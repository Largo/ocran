# frozen_string_literal: true

module Ocran
  module DirectionTools
    module_function

    # Resolves the common root directory prefix from an array of absolute paths.
    # This method iterates over each file path, checking if they have a subpath
    # that matches a given execution prefix.
    def resolve_root_prefix(files)
      files.inject(files.first.dirname) do |current_root, file|
        next current_root if file.subpath?(exec_prefix)

        current_root.ascend.find do |candidate_root|
          path_from_root = file.relative_path_from(candidate_root)
        rescue ArgumentError
          raise "No common directory contains all specified files"
        else
          path_from_root.each_filename.first != ".."
        end
      end
    end

    # For RubyInstaller environments supporting Ruby 2.4 and above,
    # this method checks for the existence of a required manifest file
    def ruby_builtin_manifest
      manifest_path = exec_prefix / "bin/ruby_builtin_dlls/ruby_builtin_dlls.manifest"
      manifest_path.exist? ? manifest_path : nil
    end

    def detect_dlls
      require_relative "library_detector"
      LibraryDetector.loaded_dlls.map { |path| Pathname.new(path).cleanpath }
    end
  end
end
