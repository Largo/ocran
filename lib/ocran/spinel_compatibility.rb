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
    # Mirrors the top-level libraries of packages/ as of Spinel 2026.11.
    FALLBACK_FEATURES = %w[
      base64 benchmark bigdecimal cgi cgi/escape cgi/util csv date did_you_mean
      digest digest/md5 digest/sha1 digest/sha2 erb erb/escape ffi fiddle
      fiddle/import fileutils find forwardable getoptlong io/buffer ipaddr json
      logger net/http net/https net/protocol net/smtp observer open3 openssl
      optparse pathname pp prettyprint psych pty racc racc/parser resolv rexml
      rexml/document securerandom set shellwords singleton sqlite3 stringio
      strscan tempfile time timeout tmpdir uri weakref yaml zlib
    ].freeze

    # Requires the compiler answers itself, without a file in packages/
    # (src/spinel_parse.c: sp_lib_is_native, sp_require_tolerated,
    # sp_require_preloaded).
    NATIVE_FEATURES = %w[
      io/console monitor time socket ostruct set
      thread enumerator fiber ffi rational complex io/wait rbconfig
    ].freeze

    # packages_dir:  Spinel's packages/ directory, if known, to read the
    #                features it provides from
    # package_roots: the -I roots of a spin project's dependencies (from
    #                `spin flags`); a library one of them holds is provided,
    #                ahead of any gem of the same name, as Spinel searches
    #                them first
    def initialize(script, packages_dir: nil, package_roots: [], project_dirs: nil)
      super(script, project_dirs: project_dirs)
      @features = spinel_features(packages_dir)
      @package_roots = package_roots
      @allowed = {}
    end

    def target = "Spinel"

    private

    def provided_feature?(feature)
      @features.include?(feature) || in_package_root?(feature)
    end

    # Spinel resolves require "x" against a root as x.rb or x/x.rb.
    def in_package_root?(feature)
      base = File.basename(feature)
      @package_roots.any? do |root|
        File.file?(File.join(root, "#{feature}.rb")) || File.file?(File.join(root, feature, "#{base}.rb"))
      end
    end

    def gem_problem(gem)
      if gem.native
        [:error, "has a C extension, which Spinel cannot compile (it builds native code only from spin packages)"]
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
            next if rel.start_with?("test/", "build/", "ext/") || rel.include?("/test/")

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
      when :instance_eval, :instance_exec
        if name == :instance_eval && string_argument?(node, args)
          flag(:error, node, "instance_eval with a string is not supported (the block form works)")
        end
      when :class_eval, :module_eval
        if string_argument?(node, args)
          # Spinel compiles the string when its text is known at compile
          # time: a literal, or a heredoc without interpolation. Some
          # interpolations (a surrounding literal-list loop variable) work too.
          case args.first
          when Prism::StringNode
            nil
          when Prism::InterpolatedStringNode
            flag(:warning, node, "#{name} of an interpolated string compiles only when Spinel can work out its text at compile time")
          else
            flag(:error, node, "#{name} of a string built at run time is not supported (a literal string or the block form works)")
          end
        end
      when :define_method
        check_define_method(node, args.first) if receiver.nil? || receiver.is_a?(Prism::SelfNode)
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
        # Class.new(Constant) is compiled, with or without a block; only a
        # superclass computed at run time is refused.
        if constant?(receiver, :Class) && (superclass = args.first) && !static_superclass?(superclass)
          flag(:error, node, "Class.new with a superclass computed at run time is not supported (a constant superclass works)")
        end
      end
    end

    # Spinel expands define_method at compile time, so it needs the names:
    # a literal, or the variable of a loop over a literal list (also inside
    # an interpolation, as in "#{n}="). In a method body a computed name
    # can still work: a class method the class body calls with literal
    # arguments is expanded call by call.
    def check_define_method(node, name)
      return if name.nil? || static_name?(name)

      if built_from_loop_vars?(name)
        flag(:warning, node, "define_method with a name built from a literal-list loop variable compiles only " \
                             "where Spinel can work the name out once it unrolls the loop")
      elsif in_def?
        flag(:warning, node, "define_method with a computed name compiles only where the method is called " \
                             "from a class body with literal arguments")
      else
        flag(:error, node, "define_method with a name computed at run time is refused (literal names, and the " \
                           "variable of a loop over a literal list or a constant, work)")
      end
    end

    def static_name?(node)
      case node
      when Prism::SymbolNode, Prism::StringNode
        true
      when Prism::InterpolatedSymbolNode, Prism::InterpolatedStringNode
        node.parts.all? do |part|
          part.is_a?(Prism::StringNode) ||
            (part.is_a?(Prism::EmbeddedStatementsNode) && part.statements&.body&.size == 1 &&
             static_name?(part.statements.body.first))
        end
      when Prism::CallNode
        # n.to_sym, n.to_s
        %i[to_sym to_s].include?(node.name) && node.arguments.nil? && static_name?(node.receiver)
      else
        literal_loop_var?(node)
      end
    end

    # An expression of literals and literal-list loop variables only, such
    # as n.to_s + "?", which unrolling the loop may make a constant.
    def built_from_loop_vars?(node)
      vars = []
      walk = lambda do |n|
        case n
        when Prism::SymbolNode, Prism::StringNode, Prism::IntegerNode then true
        when Prism::LocalVariableReadNode then literal_loop_var?(n) && vars << n
        when Prism::CallNode
          n.block.nil? && !n.receiver.nil? && walk.(n.receiver) &&
            (n.arguments&.arguments || []).all? { |a| walk.(a) }
        when Prism::InterpolatedSymbolNode, Prism::InterpolatedStringNode
          n.parts.all? { |p| p.is_a?(Prism::StringNode) || (p.is_a?(Prism::EmbeddedStatementsNode) && p.statements&.body&.size == 1 && walk.(p.statements.body.first)) }
        when Prism::ParenthesesNode
          n.body.is_a?(Prism::StatementsNode) && n.body.body.size == 1 && walk.(n.body.body.first)
        else false
        end
      end
      walk.(node) && !vars.empty?
    end

    def string_argument?(node, args)
      node.block.nil? && args.any? && !args.first.is_a?(Prism::BlockArgumentNode)
    end

    # A superclass Spinel knows at compile time: a constant, or a
    # Struct.new / Data.define call.
    def static_superclass?(node)
      case node
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        true
      when Prism::CallNode
        (node.name == :new && constant?(node.receiver, :Struct)) ||
          (node.name == :define && constant?(node.receiver, :Data))
      else
        false
      end
    end
  end
end
