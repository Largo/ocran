# frozen_string_literal: true
require "pathname"
require "rbconfig"

module Ocran
  # A static look at whether a script is likely to compile with Spinel, the
  # ahead-of-time compiler behind --spinel.
  #
  # Spinel compiles a subset of Ruby: no eval of strings, no method_missing,
  # no runtime class graph changes, and only the standard library it ships
  # itself (https://github.com/matz/spinel/blob/master/docs/limitations.md).
  # Its own errors name the first construct it rejects; this walks the whole
  # program instead - the script, the files it requires, and the source of
  # every gem it requires - and reports everything that is known to stand in
  # the way, sorted by where it comes from, so that "which of my gems can't
  # be compiled" has an answer before the first build is attempted.
  #
  # It is advice, not a verdict: Spinel is the judge of what compiles, and
  # it moves fast. Nothing here prevents a build.
  #
  # The walk also yields the -I roots that let Spinel find the pure-Ruby
  # gems and the project's own lib/ directory, since Spinel resolves
  # `require` at compile time against the roots it is given rather than
  # against the gems installed for CRuby.
  class SpinelCompatibility
    # A construct or require that will (:error) or may (:warning) fail.
    Finding = Struct.new(:severity, :origin, :path, :line, :message, keyword_init: true)

    # A gem the program requires.
    GemUse = Struct.new(:spec, :native, :stdlib, keyword_init: true) do
      def name = spec.name
      def label = "#{spec.name} #{spec.version}"
    end

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

    # Requires CRuby itself satisfies that mean nothing to a compiled program.
    IGNORED_FEATURES = %w[rubygems bundler/setup].freeze

    MAX_SHOWN_PER_ORIGIN = 8

    PROJECT = "your code"

    attr_reader :findings, :gems, :include_dirs, :files

    # script:       the program's entry file
    # packages_dir: Spinel's packages/ directory, if known, to read the
    #               features it provides from
    # project_dirs: directories whose files count as the program's own
    def initialize(script, packages_dir: nil, project_dirs: nil)
      @script = Pathname(script).expand_path
      @root = @script.dirname
      @project_dirs = (project_dirs || [@root]).map { |d| Pathname(d).expand_path }
      @features = spinel_features(packages_dir)
      @findings = []
      @gems = {}
      @include_dirs = []
      @files = []
    end

    # Walks the program. Returns self.
    def analyze
      unless prism_available?
        @prism_missing = true
        return self
      end

      queue = [[@script, PROJECT]]
      seen = {}
      until queue.empty?
        path, origin = queue.shift
        next if seen[path.to_s]

        seen[path.to_s] = true
        @files << path
        scan_file(path, origin) { |dep, dep_origin| queue << [dep, dep_origin] }
      end
      self
    end

    def errors = @findings.select { |f| f.severity == :error }

    def problem_gems
      @gems.values.select { |g| g.native || g.stdlib || @findings.any? { |f| f.severity == :error && f.origin == g.name } }
    end

    def clean?
      !@prism_missing && errors.empty?
    end

    # The report as text: a summary of the gems involved, then what was
    # found, grouped by the code it was found in.
    def report
      out = []
      if @prism_missing
        out << "The source could not be scanned: the prism gem is not available (gem install prism)."
        return out.join("\n")
      end

      unless @gems.empty?
        out << "Gems required by the program:"
        @gems.values.sort_by(&:name).each do |gem|
          out << "  #{gem_status(gem)}"
        end
        out << ""
      end

      by_origin = @findings.group_by(&:origin)
      origins = by_origin.keys.sort_by { |o| o == PROJECT ? "" : o }
      origins.each do |origin|
        list = by_origin[origin].sort_by { |f| [f.severity == :error ? 0 : 1, f.path.to_s, f.line.to_i] }
        heading = origin == PROJECT ? "In your code:" : "In gem #{@gems[origin]&.label || origin}:"
        out << heading
        list.first(MAX_SHOWN_PER_ORIGIN).each do |f|
          out << "  #{f.severity == :error ? "error" : "warning"}: #{location(f)}#{f.message}"
        end
        if list.size > MAX_SHOWN_PER_ORIGIN
          out << "  ... and #{list.size - MAX_SHOWN_PER_ORIGIN} more"
        end
        out << ""
      end

      if @findings.empty?
        out << "Nothing Spinel is known to reject was found in #{@files.size} file(s)."
      else
        errors_count = errors.size
        warnings_count = @findings.size - errors_count
        out << "#{errors_count} error(s), #{warnings_count} warning(s) in #{@files.size} scanned file(s)."
      end
      out.join("\n")
    end

    private

    def gem_status(gem)
      if gem.native
        "#{gem.label}: incompatible - has a C extension, which Spinel cannot compile"
      elsif gem.stdlib
        "#{gem.label}: incompatible - Ruby standard library that Spinel does not provide"
      elsif (n = @findings.count { |f| f.severity == :error && f.origin == gem.name }).positive?
        "#{gem.label}: likely incompatible - #{n} unsupported construct(s), see below"
      else
        "#{gem.label}: pure Ruby, nothing unsupported found (compiled from #{gem.spec.full_gem_path})"
      end
    end

    def location(f)
      return "" unless f.path

      path = display_path(f.path, @gems[f.origin])
      f.line ? "#{path}:#{f.line}: " : "#{path}: "
    end

    # Gem files relative to the gem, the program's own relative to the
    # script's directory.
    def display_path(path, gem)
      base = gem ? Pathname(gem.spec.full_gem_path) : @root
      rel = Pathname(path).relative_path_from(base).to_s
      rel.start_with?("../..") ? path.to_s : rel
    rescue ArgumentError
      path.to_s
    end

    def prism_available?
      require "prism"
      true
    rescue LoadError
      false
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

    def add(severity, origin, path, line, message)
      @findings << Finding.new(severity: severity, origin: origin, path: path, line: line, message: message)
    end

    def scan_file(path, origin, &enqueue)
      result = Prism.parse_file(path.to_s)
      result.errors.first(3).each do |e|
        add(:error, origin, path, e.location.start_line, "syntax error: #{e.message}")
      end
      self.class.visitor_class.new(self, path, origin, enqueue).visit(result.value)
    rescue SystemCallError => e
      add(:error, origin, path, nil, "cannot be read: #{e.message}")
    end

    # Called by the visitor for `require_relative "x"`.
    def require_relative(from, origin, line, name, &enqueue)
      target = Pathname(File.expand_path(name, File.dirname(from)))
      target = Pathname("#{target}.rb") unless target.extname == ".rb"
      if target.file?
        enqueue.call(target, origin)
      else
        add(:error, origin, from, line, "require_relative #{name.inspect}: #{target} does not exist")
      end
    end

    # Called by the visitor for `require "x"`.
    def require_feature(from, origin, line, name, &enqueue)
      feature = name.delete_suffix(".rb")
      return if IGNORED_FEATURES.include?(feature)
      return if @features.include?(feature)

      # The program's own files, on a load path it would set up with -I or
      # $LOAD_PATH: the script's directory and its lib/, and the require
      # paths of the gems already found (a gem requiring its own files).
      local_roots = [@root, @root + "lib"] + @include_dirs.map { |d| Pathname(d) }
      local_roots.each do |root|
        candidate = root + "#{feature}.rb"
        next unless candidate.file?

        add_include_dir(root) unless root == @root
        enqueue.call(candidate, owner_of(candidate) || (project_file?(candidate) ? PROJECT : origin))
        return
      end

      spec = find_gem(feature)
      unless spec
        if stdlib_feature?(feature)
          add(:error, origin, from, line, "require #{name.inspect}: part of Ruby's standard library, but not one Spinel provides")
        else
          add(:error, origin, from, line, "require #{name.inspect}: not a Spinel library, a project file or an installed gem")
        end
        return
      end

      gem = (@gems[spec.name] ||= classify_gem(spec))
      if gem.native || gem.stdlib
        reason = gem.native ? "a C extension Spinel cannot compile" : "Ruby standard library Spinel does not provide"
        add(:error, origin, from, line, "require #{name.inspect}: gem #{gem.label} is #{reason}") if origin == PROJECT || origin != gem.name
        return
      end

      spec.full_require_paths.each { |dir| add_include_dir(dir) }
      file = spec.full_require_paths.lazy.map { |dir| Pathname(dir) + "#{feature}.rb" }.find(&:file?)
      enqueue.call(file, spec.name) if file
    end

    def add_include_dir(dir)
      dir = dir.to_s
      @include_dirs << dir if File.directory?(dir) && !@include_dirs.include?(dir)
    end

    # The gem a file belongs to, when it is in one already found.
    def owner_of(path)
      @gems.each_value do |gem|
        return gem.name if path.to_s.start_with?(gem.spec.full_gem_path + "/")
      end
      nil
    end

    def project_file?(path)
      @project_dirs.any? { |dir| path.to_s.start_with?("#{dir}/") }
    end

    def find_gem(feature)
      Gem::Specification.find_by_path(feature)
    rescue StandardError
      nil
    end

    def classify_gem(spec)
      # A default gem is how Ruby ships its standard library. Spinel has its
      # own versions of the parts it supports (matched by name before a gem
      # is ever looked up), so any other default gem is standard library it
      # does not have, whether or not it is written in C.
      stdlib = spec.default_gem?
      native = !stdlib && (!spec.extensions.empty? ||
                           Dir.glob(File.join(spec.full_gem_path, "**", "*.{so,bundle,dll}")).any?)
      GemUse.new(spec: spec, native: native, stdlib: stdlib)
    end

    def stdlib_feature?(feature)
      %w[rubylibdir rubyarchdir].any? do |key|
        dir = RbConfig::CONFIG[key] or next false
        Dir.glob(File.join(dir, "#{feature}.{rb,so,bundle,dll}")).any?
      end
    end

    # The class that walks one file's syntax tree. Built on first use so
    # that Prism is only needed when a scan actually runs.
    def self.visitor_class
      @visitor_class ||= build_visitor
    end

    def self.build_visitor
      Class.new(Prism::Visitor) do
        def initialize(analysis, path, origin, enqueue)
          super()
          @analysis = analysis
          @path = path
          @origin = origin
          @enqueue = enqueue
          @allowed = {}
        end

        def visit_call_node(node)
          check_call(node)
          super
        end

        def visit_def_node(node)
          if node.name == :method_missing
            flag(:warning, node, "method_missing is never dispatched by Spinel; calls to undefined methods fail to compile")
          end
          super
        end

        def visit_global_variable_read_node(node)
          if %i[$LOAD_PATH $:].include?(node.name)
            flag(:warning, node, "#{node.name} has no effect: Spinel resolves every require at compile time")
          end
          super
        end

        def visit_constant_read_node(node)
          if node.name == :TracePoint
            flag(:error, node, "TracePoint is not supported (it needs an interpreter loop)")
          end
          super
        end

        private

        def check_call(node)
          return if @allowed[node.object_id]

          name = node.name
          args = node.arguments&.arguments || []
          receiver = node.receiver
          kernel = receiver.nil? || (receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :Kernel)

          case name
          when :require, :require_relative
            return unless kernel

            arg = args.first
            if arg.is_a?(Prism::StringNode)
              meth = name == :require ? :require_feature : :require_relative
              @analysis.send(meth, @path, @origin, line(node), arg.unescaped, &@enqueue)
            elsif arg
              flag(:error, node, "#{name} with a computed name: Spinel resolves requires at compile time, so the name must be a string literal")
            end
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
            if receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :ObjectSpace
              flag(:error, node, "ObjectSpace.#{name} is not supported")
            end
          when :set_trace_func
            flag(:error, node, "set_trace_func is not supported") if kernel
          when :callcc
            flag(:error, node, "callcc / Continuation is not supported") if kernel
          when :refine, :using
            if receiver.nil? && args.size == 1 && (node.block || name == :using)
              flag(:error, node, "refinements (refine / using) are not supported")
            end
          when :new
            if receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :Class
              flag(:error, node, "Class.new builds a class at run time, which is not supported")
            end
          end
        end

        def literal?(node)
          node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
        end

        def line(node) = node.location.start_line

        def flag(severity, node, message)
          @analysis.send(:add, severity, @origin, @path, line(node), message)
        end
      end
    end
    private_class_method :build_visitor
  end
end
