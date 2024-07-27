# frozen_string_literal: true
require "pathname"
require_relative "refine_pathname"

module Ocran
  class FilePathSet
    using RefinePathname
    include Enumerable

    def initialize
      @set = {}
    end

    def add(source, target)
      add?(source, target)
      self
    end

    # Adds a source and target path pair to the set and validates the paths before adding.
    # This method performs various checks to ensure the source path is an absolute path
    # and the target path is a relative path that does not include '.' or '..'.
    # If a conflict is detected (i.e., different source for the same target),
    # it raises an exception.
    #
    # @param [String, Pathname] source - The source file path; must be an absolute path.
    # @param [String, Pathname] target - The target file path; must be a relative path.
    # @return [self, nil] Returns self if the path pair is added successfully,
    #                     returns nil if the same source and target pair is already present.
    # @raise [ArgumentError] If the source is not an absolute path, if the target is not a relative path,
    #                        or if the target includes '.' or '..'.
    # @raise [RuntimeError] If a conflicting source is found for the same target.
    def add?(source, target)
      source = Pathname.new(source) unless source.is_a?(Pathname)
      source = source.cleanpath
      unless source.absolute?
        raise ArgumentError, "Source path must be absolute, given: #{source}"
      end

      target = Pathname.new(target) unless target.is_a?(Pathname)
      target = target.cleanpath
      unless target.relative?
        raise ArgumentError, "Target path must be relative, given: #{target}"
      end
      if %w(. ..).include?(target.each_filename.first)
        raise ArgumentError, "Relative paths such as '.' or '..' are not allowed, given: #{target}"
      end

      if (path = @set[target])
        if path.eql?(source)
          return nil
        else
          raise "Conflicting sources for the same target. Target: #{target}, Existing Source: #{path}, Given Source: #{source}"
        end
      end

      @set[target] = source
      self
    end

    def each
      return to_enum(__method__) unless block_given?
      @set.each { |target, source| yield(source, target) }
    end

    def to_a
      each.to_a
    end
  end
end
