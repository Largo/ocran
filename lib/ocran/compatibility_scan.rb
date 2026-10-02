# frozen_string_literal: true
require "pathname"
require "rbconfig"

module Ocran
  # A static look at whether a program is likely to run on a Ruby other
  # than the one OCRAN normally packages: Spinel (--spinel), ruby.wasm and
  # PicoRuby (--wasm). Each of them runs a subset of what CRuby runs, and
  # their own errors name the first thing they trip over at best. This walks
  # the whole program instead - the script, the files it requires, and the
  # source of every gem it requires - and reports everything known to stand
  # in the way, sorted by where it comes from, so that "which of my gems
  # won't work" has an answer before the first build is attempted.
  #
  # It is advice, not a verdict: nothing here prevents a build. Subclasses
  # say what their target provides and what it rejects; the walk, the
  # require resolution and the report are shared.
  class CompatibilityScan
    # A construct or require that will (:error) or may (:warning) fail.
    Finding = Struct.new(:severity, :origin, :path, :line, :message, keyword_init: true)

    # A gem the program requires.
    GemUse = Struct.new(:spec, :native, :stdlib, keyword_init: true) do
      def name = spec.name
      def label = "#{spec.name} #{spec.version}"
    end

    # A `require` or `require_relative` of one of the program's own files,
    # by byte range in the requiring file.
    LocalRequire = Struct.new(:from, :start_offset, :end_offset, :target, keyword_init: true)

    # Requires CRuby itself satisfies that mean nothing outside it.
    IGNORED_FEATURES = %w[rubygems bundler/setup].freeze

    MAX_SHOWN_PER_ORIGIN = 8

    PROJECT = "your code"

    attr_reader :findings, :gems, :include_dirs, :files, :local_requires

    # The scanned files that are the program's own rather than a gem's.
    attr_reader :project_files

    # script:       the program's entry file
    # project_dirs: directories whose files count as the program's own
    def initialize(script, project_dirs: nil)
      @script = Pathname(script).expand_path
      @root = @script.dirname
      @project_dirs = (project_dirs || [@root]).map { |d| Pathname(d).expand_path }
      @findings = []
      @gems = {}
      @include_dirs = []
      @files = []
      @project_files = []
      @local_requires = []
    end

    # The name the report uses for the target, e.g. "Spinel".
    def target = raise(NotImplementedError)

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
        @project_files << path if origin == PROJECT
        scan_file(path, origin) { |dep, dep_origin| queue << [dep, dep_origin] }
      end
      self
    end

    def errors = @findings.select { |f| f.severity == :error }

    def problem_gems
      @gems.values.select { |g| gem_problem(g) || @findings.any? { |f| f.severity == :error && f.origin == g.name } }
    end

    def clean?
      !@prism_missing && errors.empty?
    end

    def scanned? = !@prism_missing

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
          out << "  #{gem.label}: #{gem_status(gem)}"
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
        out << "Nothing #{target} is known to reject was found in #{@files.size} file(s)."
      else
        errors_count = errors.size
        warnings_count = @findings.size - errors_count
        out << "#{errors_count} error(s), #{warnings_count} warning(s) in #{@files.size} scanned file(s)."
      end
      out.join("\n")
    end

    private

    # --- Hooks for subclasses -------------------------------------------

    # True when the target provides the feature itself, so `require` of it
    # needs nothing from the host.
    def provided_feature?(_feature) = false

    # Why the target cannot use the given library (by its require name),
    # as [severity, reason], or nil to resolve it as usual.
    def feature_problem(_feature) = nil

    # Why the target cannot use the given gem, as [severity, reason], or nil
    # when it can. A gem without a problem has its source scanned too.
    def gem_problem(_gem) = nil

    # The status line of a gem in the report.
    def gem_status(gem)
      if (problem = gem_problem(gem))
        "#{problem[0] == :error ? "incompatible" : "may not work"} - #{problem[1]}"
      elsif (n = @findings.count { |f| f.severity == :error && f.origin == gem.name }).positive?
        "likely incompatible - #{n} unsupported construct(s), see below"
      else
        "pure Ruby, nothing unsupported found"
      end
    end

    # Called with a gem the program requires that has no problem, before
    # its source is scanned. Spinel compiles gems from source, so it makes
    # their require paths -I roots.
    def gem_used(gem); end

    # What to say about `require` of a standard library the target lacks,
    # or nil when the target has Ruby's whole standard library.
    def missing_stdlib_message(name) = "require #{name.inspect}: part of Ruby's standard library, but not one #{target} provides"

    def unresolved_message(name) = "require #{name.inspect}: not a #{target} library, a project file or an installed gem"

    def dynamic_require_message(name) = "#{name} with a computed name: the file cannot be found before the program runs"

    # Per-node checks: called with the node, and flag findings with #flag.
    def check_call(_node, _name, _args, _receiver, _kernel); end
    def check_def(_node); end
    def check_global(_node); end
    def check_constant(_node); end
    def check_xstring(_node); end

    # --- Shared machinery -----------------------------------------------

    def flag(severity, node, message)
      add(severity, @current_origin, @current_path, node&.location&.start_line, message)
    end

    def literal?(node)
      node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
    end

    def kernel_receiver?(receiver)
      receiver.nil? || (receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :Kernel)
    end

    def constant?(node, name)
      node.is_a?(Prism::ConstantReadNode) && node.name == name
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

    def add(severity, origin, path, line, message)
      @findings << Finding.new(severity: severity, origin: origin, path: path, line: line, message: message)
    end

    def scan_file(path, origin, &enqueue)
      result = Prism.parse_file(path.to_s)
      @current_path = path
      @current_origin = origin
      @enqueue = enqueue
      result.errors.first(3).each do |e|
        add(:error, origin, path, e.location.start_line, "syntax error: #{e.message}")
      end
      Visitor.new(self).visit(result.value)
    rescue SystemCallError => e
      add(:error, origin, path, nil, "cannot be read: #{e.message}")
    end

    # Every call: requires are resolved here, the rest goes to the target's
    # check_call.
    def visit_call(node)
      name = node.name
      args = node.arguments&.arguments || []
      receiver = node.receiver
      kernel = kernel_receiver?(receiver)

      if %i[require require_relative].include?(name) && kernel
        arg = args.first
        if arg.is_a?(Prism::StringNode)
          if name == :require
            require_feature(node, arg.unescaped)
          else
            require_relative(node, arg.unescaped)
          end
        elsif arg
          flag(:error, node, dynamic_require_message(name))
        end
        return
      end

      check_call(node, name, args, receiver, kernel)
    end

    def require_relative(node, name)
      target = Pathname(File.expand_path(name, File.dirname(@current_path)))
      target = Pathname("#{target}.rb") unless target.extname == ".rb"
      if target.file?
        record_local(node, target)
        @enqueue.call(target, @current_origin)
      else
        flag(:error, node, "require_relative #{name.inspect}: #{target} does not exist")
      end
    end

    def require_feature(node, name)
      feature = name.delete_suffix(".rb")
      return if IGNORED_FEATURES.include?(feature)

      if (problem = feature_problem(feature))
        flag(problem[0], node, "require #{name.inspect}: #{problem[1]}")
        return
      end
      return if provided_feature?(feature)

      # The program's own files, on a load path it would set up with -I or
      # $LOAD_PATH: the script's directory and its lib/, and the require
      # paths of the gems already found (a gem requiring its own files).
      local_roots = [@root, @root + "lib"] + @include_dirs.map { |d| Pathname(d) }
      local_roots.each do |root|
        candidate = root + "#{feature}.rb"
        next unless candidate.file?

        add_include_dir(root) unless root == @root
        owner = owner_of(candidate) || (project_file?(candidate) ? PROJECT : @current_origin)
        record_local(node, candidate) if owner == PROJECT
        @enqueue.call(candidate, owner)
        return
      end

      spec = find_gem(feature)
      unless spec
        message = stdlib_feature?(feature) ? missing_stdlib_message(name) : unresolved_message(name)
        flag(:error, node, message) if message
        return
      end

      gem = (@gems[spec.name] ||= classify_gem(spec))
      if (problem = gem_problem(gem))
        # Reported once per requiring site outside the gem itself.
        flag(problem[0], node, "require #{name.inspect}: gem #{gem.label} - #{problem[1]}") if @current_origin != gem.name
        return
      end

      gem_used(gem)
      spec.full_require_paths.each { |dir| add_include_dir(dir) }
      file = spec.full_require_paths.lazy.map { |dir| Pathname(dir) + "#{feature}.rb" }.find(&:file?)
      @enqueue.call(file, spec.name) if file
    end

    def record_local(node, target)
      return unless @current_origin == PROJECT

      @local_requires << LocalRequire.new(from: @current_path, start_offset: node.location.start_offset,
                                          end_offset: node.location.end_offset, target: target)
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
      # A default gem is how Ruby ships its standard library.
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

    # Walks one file's syntax tree, handing every node of interest to the
    # scan. Defined on first use, so that Prism is only loaded when a scan
    # actually runs.
    def self.const_missing(name)
      return super unless name == :Visitor

      require "prism"
      visitor = Class.new(Prism::Visitor) do
        def initialize(scan)
          super()
          @scan = scan
        end

        def visit_call_node(node)
          @scan.send(:visit_call, node)
          super
        end

        def visit_def_node(node)
          @scan.send(:check_def, node)
          super
        end

        def visit_global_variable_read_node(node)
          @scan.send(:check_global, node)
          super
        end

        def visit_constant_read_node(node)
          @scan.send(:check_constant, node)
          super
        end

        def visit_x_string_node(node)
          @scan.send(:check_xstring, node)
          super
        end

        def visit_interpolated_x_string_node(node)
          @scan.send(:check_xstring, node)
          super
        end
      end
      CompatibilityScan.const_set(:Visitor, visitor)
    end
  end
end
