# frozen_string_literal: true
require_relative "compatibility_scan"

module Ocran
  # Whether a script is likely to compile with Spinel, the ahead-of-time
  # compiler behind --spinel.
  #
  # Spinel compiles a subset of Ruby: no eval of strings, no method_missing,
  # no runtime class graph changes, and only the standard library it ships
  # itself (https://github.com/matz/spinel/blob/master/docs/limitations.md).
  #
  # The walk also yields the -I roots that let Spinel find the pure-Ruby
  # gems and the project's own lib/ directory, since Spinel resolves
  # `require` at compile time against the roots it is given rather than
  # against the gems installed for CRuby.
  class SpinelCompatibility < CompatibilityScan
    # Features Spinel provides when its own packages/ directory cannot be
    # found to read the list from (it is installed beside the compiler).
    # Mirrors packages/ plus the requires the compiler answers natively
    # (src/spinel_parse.c: sp_lib_is_native, sp_require_tolerated,
    # sp_require_preloaded) as of Spinel 2026.09.
    FALLBACK_FEATURES = %w[
      base64 benchmark bigdecimal cgi cgi/escape cgi/util csv digest digest/md5
      digest/sha1 digest/sha2 erb ffi fiddle fiddle/import fileutils forwardable
      io/buffer json logger net/http open3 openssl optparse pathname
      securerandom set stringio strscan tempfile tmpdir uri zlib
    ].freeze

    NATIVE_FEATURES = %w[
      io/console monitor time socket ostruct
      thread enumerator fiber rational complex
    ].freeze

    # packages_dir: Spinel's packages/ directory, if known, to read the
    #               features it provides from
    def initialize(script, packages_dir: nil, project_dirs: nil)
      super(script, project_dirs: project_dirs)
      @features = spinel_features(packages_dir)
      @allowed = {}
    end

    def target = "Spinel"

    private

    def provided_feature?(feature) = @features.include?(feature)

    def gem_problem(gem)
      if gem.native
        [:error, "has a C extension, which Spinel cannot compile"]
      elsif gem.stdlib
        # Spinel has its own versions of the parts of the standard library
        # it supports (matched by name before a gem is ever looked up), so
        # any other default gem is standard library it does not have.
        [:error, "Ruby standard library that Spinel does not provide"]
      end
    end

    def gem_status(gem)
      return super if gem_problem(gem) || @findings.any? { |f| f.severity == :error && f.origin == gem.name }

      "pure Ruby, nothing unsupported found (compiled from #{gem.spec.full_gem_path})"
    end

    def dynamic_require_message(name)
      "#{name} with a computed name: Spinel resolves requires at compile time, so the name must be a string literal"
    end

    def spinel_features(packages_dir)
      features = NATIVE_FEATURES.dup
      if packages_dir && File.directory?(packages_dir)
        Dir.glob(File.join(packages_dir, "*")).each do |pkg|
          Dir.glob("**/*.rb", base: pkg).each do |rel|
            next if rel.start_with?("test/", "build/") || rel.include?("/test/")

            features << rel.delete_suffix(".rb")
          end
        end
      else
        features.concat(FALLBACK_FEATURES)
      end
      features.uniq
    end

    def check_def(node)
      if node.name == :method_missing
        flag(:warning, node, "method_missing is never dispatched by Spinel; calls to undefined methods fail to compile")
      end
    end

    def check_global(node)
      if %i[$LOAD_PATH $:].include?(node.name)
        flag(:warning, node, "#{node.name} has no effect: Spinel resolves every require at compile time")
      end
    end

    def check_constant(node)
      flag(:error, node, "TracePoint is not supported (it needs an interpreter loop)") if node.name == :TracePoint
    end

    def check_call(node, name, args, receiver, kernel)
      return if @allowed[node.object_id]

      case name
      when :load
        flag(:error, node, "load: a compiled program cannot load Ruby files at run time") if kernel && !args.empty?
      when :eval
        flag(:error, node, "eval of a string is not supported (no parser at run time)") if kernel
      when :instance_eval, :class_eval, :module_eval, :class_exec
        if node.block.nil? && args.any? && !args.first.is_a?(Prism::BlockArgumentNode)
          flag(:error, node, "#{name} with a string is not supported (the block form works)")
        end
      when :define_method
        unless literal?(args.first)
          flag(:warning, node, "define_method with a computed name works only where Spinel can enumerate the names at compile time")
        end
      when :instance_variable_get, :instance_variable_set
        unless literal?(args.first)
          flag(:error, node, "#{name} with a computed name is not supported (only literal names like :@x)")
        end
      when :send, :public_send, :__send__
        if args.first && !literal?(args.first)
          flag(:warning, node, "#{name} with a computed method name only dispatches to methods named literally somewhere in the program")
        end
      when :binding
        if kernel && args.empty?
          flag(:error, node, "binding as an object is not supported (only binding.local_variable_get(:literal))")
        end
      when :local_variable_get
        # binding.local_variable_get(:x) with a literal name is supported.
        if receiver.is_a?(Prism::CallNode) && receiver.name == :binding && literal?(args.first)
          @allowed[receiver.object_id] = true
        end
      when :each_object, :count_objects
        flag(:error, node, "ObjectSpace.#{name} is not supported") if constant?(receiver, :ObjectSpace)
      when :set_trace_func
        flag(:error, node, "set_trace_func is not supported") if kernel
      when :callcc
        flag(:error, node, "callcc / Continuation is not supported") if kernel
      when :refine, :using
        if receiver.nil? && args.size == 1 && (node.block || name == :using)
          flag(:error, node, "refinements (refine / using) are not supported")
        end
      when :new
        flag(:error, node, "Class.new builds a class at run time, which is not supported") if constant?(receiver, :Class)
      end
    end
  end
end
