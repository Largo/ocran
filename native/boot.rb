# ocran native runtime, stage 1 (ocran/boot.rb inside the archive).
#
# Serves the archive appended to the executable as a read-only directory
# tree rooted at the executable's own path, e.g. C:/apps/tool.exe/src/app.rb.
# A path below an existing *file* can never exist on disk, so archive paths
# cannot be shadowed by planted files, and anything this layer does not
# handle fails loudly (ENOTDIR) instead of silently reading something else.
#
# Intercepted, and nothing else:
#   Kernel:  require, require_relative, load, open (autoload goes through require)
#   IO/File: read, binread, readlines, foreach, open
#   File:    exist? file? directory? readable? size size? zero? empty?
#            mtime ftype stat lstat realpath realdirpath symlink? executable?
#   Dir:     exist? glob [] children entries each_child foreach empty?
# Writes to archive paths raise Errno::EROFS.
module OcranRuntime
  ROOT = EXE # archive members live at "#{ROOT}/<name>"
  PREFIX = "#{ROOT}/".freeze

  module VirtualFS
    module_function

    # Member names of files; "dir/" entries only contribute to dirs.
    def files
      @files ||= OcranRuntime.entries.keys.reject { |n| n.end_with?("/") }.freeze
    end

    def dirs
      @dirs ||= begin
        set = { ROOT => true }
        OcranRuntime.entries.each_key do |name|
          parts = name.split("/")
          parts.pop unless name.end_with?("/")
          parts.each_index { |i| set["#{ROOT}/#{parts[0..i].join("/")}"] = true }
        end
        set.freeze
      end
    end

    def paths
      @paths ||= (files.map { |n| "#{ROOT}/#{n}" } + dirs.keys).sort.freeze
    end

    # Absolute virtual path for +path+, or nil when it is not an archive path.
    def vpath(path)
      path = path.to_path if path.respond_to?(:to_path)
      return nil unless path.is_a?(String)
      path = File.expand_path(path)
      path.start_with?(PREFIX) || path == ROOT ? path : nil
    end

    def file?(path) = (v = vpath(path)) && v != ROOT ? OcranRuntime.entries.key?(v.delete_prefix(PREFIX)) : false
    def directory?(path) = (v = vpath(path)) ? dirs.key?(v) : false
    def exist?(path) = file?(path) || directory?(path)

    def read(path)
      v = vpath(path)
      raise Errno::EISDIR, path.to_s if v && dirs.key?(v)
      data = v && OcranRuntime.read(v.delete_prefix(PREFIX))
      raise Errno::ENOENT, path.to_s unless data
      data
    end

    def children(path)
      v = vpath(path)
      raise Errno::ENOENT, path.to_s unless v && dirs.key?(v)
      prefix = "#{v}/"
      paths.filter_map { |p| p.delete_prefix(prefix).split("/").first if p.start_with?(prefix) }.uniq
    end

    def glob(pattern, flags, base)
      pattern = File.join(File.expand_path(base), pattern) if base
      flags |= File::FNM_PATHNAME | File::FNM_EXTGLOB
      found = paths.select { |p| File.fnmatch?(pattern, p, flags) }
      base ? found.map { |p| p.delete_prefix("#{File.expand_path(base)}/") } : found
    end

    def stat(path)
      raise Errno::ENOENT, path.to_s unless exist?(path)
      e = OcranRuntime.entries[vpath(path).delete_prefix(PREFIX)]
      Stat.new(e ? e.size : 0, e.nil?)
    end

    # The subset of File::Stat that libraries ask about.
    Stat = Struct.new(:size, :directory?) do
      def file? = !directory?
      def ftype = directory? ? "directory" : "file"
      def mtime = File.mtime(EXE)
      alias_method :ctime, :mtime
      alias_method :atime, :mtime
      def readable? = true
      def writable? = false
      def executable? = false
      def symlink? = false
      def zero? = size.zero?
      def size? = size.zero? ? nil : size
      def mode = directory? ? 0o40555 : 0o100444
    end

    def writing?(mode, opts)
      mode = opts[:mode] || mode
      case mode
      when String then mode.match?(/[wa+]/)
      when Integer then mode & (File::WRONLY | File::RDWR | File::CREAT) != 0
      else false
      end
    end

    def contents(path, mode, opts)
      data = read(path)
      mode = (opts[:mode] || mode).to_s
      enc = opts[:encoding] || opts[:external_encoding] || mode[/:([^:]+)/, 1]
      if opts[:binmode] || mode.include?("b") && enc.nil?
        data.force_encoding(Encoding::BINARY)
      else
        data.force_encoding(enc ? Encoding.find(enc.to_s.sub(/\Abom\|/i, "")) : Encoding.default_external)
      end
    end

    def open_io(path, mode, opts)
      raise Errno::EROFS, path.to_s if writing?(mode, opts)
      io = StringIO.new(contents(path, mode, opts))
      v = vpath(path)
      io.define_singleton_method(:path) { v }
      io.define_singleton_method(:to_path) { v }
      io
    end
  end

  # ---- require / load -------------------------------------------------
  @lock = Thread::Mutex.new
  @loaded = {}

  class << self
    attr_reader :config

    def synchronize(&)
      @lock.owned? ? yield : @lock.synchronize(&)
    end

    def compile(path)
      src = VirtualFS.read(path).force_encoding(Encoding::UTF_8)
      RubyVM::InstructionSequence.compile(src, path, path, 1)
    end

    def load_file(path, wrap)
      if wrap
        mod = wrap.is_a?(Module) ? wrap : Module.new
        mod.module_eval(VirtualFS.read(path).force_encoding(Encoding::UTF_8), path, 1)
      else
        compile(path).eval
      end
    end

    # Absolute archive path for +feature+, or nil to let Ruby handle it
    # (files on disk and the statically linked extensions).
    def resolve(feature)
      feature = feature.to_path if feature.respond_to?(:to_path)
      feature = feature.to_str
      ext = File.extname(feature)
      return nil if ext == ".so" || ext == ".dll"
      name = ext == ".rb" ? feature : "#{feature}.rb"
      if File.absolute_path?(feature) || feature.start_with?("./", "../", "~")
        path = File.expand_path(name)
        return VirtualFS.file?(path) ? path : nil
      end
      $LOAD_PATH.each do |dir|
        dir = VirtualFS.vpath(dir) or next
        path = "#{dir}/#{name}"
        return path if VirtualFS.file?(path)
      end
      nil
    end

    def require_virtual(path)
      synchronize do
        return false if @loaded[path] || $LOADED_FEATURES.include?(path)
        # Recorded as loaded *before* evaluation: a circular require then
        # returns false, and an autoload being satisfied by this file sees
        # its feature as provided (MRI's own require uses an internal
        # loading table for that, which Ruby code cannot reach).
        @loaded[path] = true
        $LOADED_FEATURES << path
        begin
          compile(path).eval
        rescue Exception
          @loaded.delete(path)
          $LOADED_FEATURES.delete(path)
          raise
        end
        true
      end
    end
  end

  module KernelPatch
    private

    def require(feature)
      path = OcranRuntime.resolve(feature)
      path ? OcranRuntime.require_virtual(path) : super
    end

    def require_relative(feature)
      base = caller_locations(1, 1).first&.absolute_path
      return super unless base && VirtualFS.vpath(base)
      require(File.expand_path(feature, File.dirname(base)))
    end

    def load(file, wrap = false)
      return super unless VirtualFS.file?(file)
      OcranRuntime.load_file(VirtualFS.vpath(file), wrap)
      true
    end

    def open(path, *args, **opts, &block)
      return super unless VirtualFS.vpath(path)
      File.open(path, *args, **opts, &block)
    end
  end

  # Kernel.require and friends, called with an explicit receiver.
  module KernelSingletonPatch
    %i[require require_relative load].each do |m|
      define_method(m) { |*args, **kw| Object.new.__send__(m, *args, **kw) }
    end
  end

  module IOPatch
    def read(path, *args, **opts)
      return super unless VirtualFS.vpath(path)
      data = VirtualFS.contents(path, "r", opts)
      length, offset = args
      offset ? data.byteslice(offset, length || data.bytesize) : length ? data.byteslice(0, length) : data
    end

    def binread(path, *args)
      return super unless VirtualFS.vpath(path)
      read(path, *args, mode: "rb")
    end

    def readlines(path, *args, chomp: false, **opts)
      return super unless VirtualFS.vpath(path)
      VirtualFS.contents(path, "r", opts).lines(*args, chomp: chomp)
    end

    def foreach(path, *args, chomp: false, **opts, &block)
      return super unless VirtualFS.vpath(path)
      lines = VirtualFS.contents(path, "r", opts).each_line(*args, chomp: chomp)
      block ? lines.each(&block) && nil : lines
    end

    def open(path, *args, **opts)
      return super unless self <= File && VirtualFS.vpath(path)
      io = VirtualFS.open_io(path, args.first, opts)
      return io unless block_given?
      begin
        yield io
      ensure
        io.close
      end
    end
  end

  module FilePatch
    %i[exist? file? directory?].each do |m|
      define_method(m) { |path| VirtualFS.vpath(path) ? VirtualFS.__send__(m, path) : super(path) }
    end

    def readable?(path) = VirtualFS.vpath(path) ? VirtualFS.exist?(path) : super
    def symlink?(path) = VirtualFS.vpath(path) ? false : super
    def executable?(path) = VirtualFS.vpath(path) ? false : super
    def size(path) = VirtualFS.vpath(path) ? VirtualFS.stat(path).size : super
    def size?(path) = VirtualFS.vpath(path) ? (VirtualFS.exist?(path) ? VirtualFS.stat(path).size? : nil) : super
    def zero?(path) = VirtualFS.vpath(path) ? VirtualFS.file?(path) && VirtualFS.stat(path).zero? : super
    alias_method :empty?, :zero?
    def mtime(path) = VirtualFS.vpath(path) ? VirtualFS.stat(path).mtime : super
    def ftype(path) = VirtualFS.vpath(path) ? VirtualFS.stat(path).ftype : super
    def stat(path) = VirtualFS.vpath(path) ? VirtualFS.stat(path) : super
    alias_method :lstat, :stat

    def realpath(path, dir = nil)
      v = VirtualFS.vpath(dir ? File.expand_path(path, dir) : path)
      return super unless v
      raise Errno::ENOENT, path.to_s unless VirtualFS.exist?(v)
      v
    end

    def realdirpath(path, dir = nil)
      v = VirtualFS.vpath(dir ? File.expand_path(path, dir) : path)
      v || super
    end
  end

  module DirPatch
    def exist?(path) = VirtualFS.vpath(path) ? VirtualFS.directory?(path) : super

    def empty?(path)
      VirtualFS.vpath(path) ? VirtualFS.children(path).empty? : super
    end

    def children(path, **opts) = VirtualFS.vpath(path) ? VirtualFS.children(path) : super
    def entries(path, **opts) = VirtualFS.vpath(path) ? [".", ".."] + VirtualFS.children(path) : super

    def each_child(path, **opts, &block)
      return super unless VirtualFS.vpath(path)
      block ? VirtualFS.children(path).each(&block) && nil : VirtualFS.children(path).each
    end

    def foreach(path, **opts, &block)
      return super unless VirtualFS.vpath(path)
      block ? entries(path).each(&block) && nil : entries(path).each
    end

    def glob(pattern, flags = 0, base: nil, sort: true, &block)
      patterns = Array(pattern).flat_map { |p| p.respond_to?(:to_path) ? p.to_path : p }
      virtual, real = patterns.partition do |p|
        VirtualFS.vpath(base ? File.join(base, p) : p.sub(/[*?\[{].*/m, ""))
      end
      found = virtual.flat_map { |p| VirtualFS.glob(p, flags, base) }
      found += super(real, flags, base: base, sort: sort) unless real.empty?
      block ? found.each(&block) && nil : found
    end

    def [](*patterns, base: nil, sort: true) = glob(patterns, base: base, sort: sort)
  end

  # ---- start ------------------------------------------------------------
  @config = TOPLEVEL_BINDING.eval(read("ocran/config.rb").force_encoding(Encoding::UTF_8),
                                  "#{PREFIX}ocran/config.rb", 1).freeze

  $LOAD_PATH.replace(@config.fetch(:load_path).map { |dir| "#{PREFIX}#{dir}" })
  Kernel.prepend(KernelPatch)
  Kernel.singleton_class.prepend(KernelSingletonPatch)
  require "stringio" # statically linked
  IO.singleton_class.prepend(IOPatch)
  File.singleton_class.prepend(FilePatch)
  Dir.singleton_class.prepend(DirPatch)

  @config.fetch(:env, {}).each { |k, v| ENV[k] = v.gsub("<ROOT>", ROOT) }
  if @config[:rubygems]
    require "rubygems"
    Gem.clear_paths
  end

  main = "#{PREFIX}#{@config.fetch(:main)}"
  $0 = main
  src = VirtualFS.read(main).force_encoding(Encoding::UTF_8)
  if (i = src.index(/^__END__\r?\n/))
    data = StringIO.new(src.byteslice(src.index("\n", i) + 1..))
    Object.const_set(:DATA, data)
  end
  ARGV.unshift(*@config.fetch(:argv, []))
end

OcranRuntime.compile($0).eval
