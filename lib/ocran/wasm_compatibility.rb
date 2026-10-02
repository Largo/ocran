# frozen_string_literal: true
require_relative "compatibility_scan"

module Ocran
  # Whether a program is likely to run in the browser on ruby.wasm, CRuby
  # compiled to WebAssembly (--wasm).
  #
  # ruby.wasm is CRuby with its whole standard library, so the language is
  # not the problem; the platform is. WASI has no threads, no processes and
  # no sockets, the browser has no standard input, and a blocking call
  # freezes the page. Gems reach the module only through a Gemfile, which
  # rbwasm packs, cross-compiling C extensions for WASI where it can.
  #
  # All of it fails at run time, when the program gets there, so what is
  # found here is reported as warnings: a program that never takes the path
  # works fine.
  class RubyWasmCompatibility < CompatibilityScan
    # Libraries that load, but whose point is something the browser does not
    # offer.
    UNAVAILABLE = {
      "socket" => "WebAssembly in the browser has no sockets; talk to servers with fetch through the js gem",
      "net/http" => "WebAssembly in the browser has no sockets; use fetch through the js gem (JS.global.fetch(url).await)",
      "net/https" => "WebAssembly in the browser has no sockets; use fetch through the js gem",
      "open-uri" => "WebAssembly in the browser has no sockets; use fetch through the js gem",
      "open3" => "WebAssembly has no processes to run",
      "pty" => "WebAssembly has no processes or terminals",
      "io/console" => "the browser has no console to control",
      "readline" => "the browser has no terminal input",
      "reline" => "the browser has no terminal input",
    }.freeze

    PROCESS_CALLS = %i[system spawn exec fork].freeze

    # gemfile_gems: names of the gems the application's Gemfile.lock lists,
    #               or nil when it has no Gemfile
    def initialize(script, gemfile_gems: nil, project_dirs: nil)
      super(script, project_dirs: project_dirs)
      @gemfile_gems = gemfile_gems
    end

    def target = "ruby.wasm"

    private

    def feature_problem(feature)
      reason = UNAVAILABLE[feature] or return nil
      [:warning, reason]
    end

    # The whole standard library is in ruby.wasm.
    def provided_feature?(feature)
      return true if stdlib_feature?(feature)

      spec = find_gem(feature)
      spec&.default_gem? || false
    end

    def missing_stdlib_message(_name) = nil

    def gem_problem(gem)
      return nil if gem.stdlib

      if @gemfile_gems.nil?
        [:error, "the application has no Gemfile, and ruby.wasm only contains the gems a Gemfile lists"]
      elsif !@gemfile_gems.include?(gem.name)
        [:error, "not in the application's Gemfile.lock, and ruby.wasm only contains the gems it lists"]
      elsif gem.native
        [:warning, "has a C extension, which rbwasm cross-compiles for WASI; extensions that link system " \
                   "libraries (libxml2, sqlite, openssl, ...) usually fail to build"]
      end
    end

    def check_call(node, name, args, receiver, kernel)
      case name
      when *PROCESS_CALLS
        if kernel || constant?(receiver, :Process)
          flag(:warning, node, "#{name}: WebAssembly has no processes to run")
        end
      when :popen
        flag(:warning, node, "IO.popen: WebAssembly has no processes to run") if constant?(receiver, :IO)
      when :new, :start, :fork
        if constant?(receiver, :Thread)
          flag(:warning, node, "Thread.#{name}: ruby.wasm has no threads (WASI provides none); " \
                               "use Fiber, or JS promises with #await")
        end
      when :gets, :readline, :readlines
        if kernel || constant?(receiver, :STDIN)
          flag(:warning, node, "#{name}: the browser has no standard input; read from the page through the js gem")
        end
      when :sleep
        if kernel && !args.empty?
          flag(:warning, node, "sleep blocks the browser's only thread and freezes the page while it waits")
        end
      when :trap
        flag(:warning, node, "trap: there are no signals in the browser") if kernel || constant?(receiver, :Signal)
      end
    end

    def check_global(node)
      return unless node.name == :$stdin

      flag(:warning, node, "$stdin: the browser has no standard input")
    end

    def check_xstring(node)
      flag(:warning, node, "backticks: WebAssembly has no processes to run")
    end
  end

  # Whether a program is likely to run in the browser on PicoRuby
  # (--wasm=picoruby), the mruby-based Ruby for microcontrollers and
  # WebAssembly.
  #
  # PicoRuby implements the core language but not CRuby's standard library
  # or RubyGems: `require` finds only the libraries compiled into the
  # runtime and files on its own virtual file system, which in the browser
  # holds nothing of the application. OCRAN therefore bundles the
  # program's own files into one script, and anything else it requires
  # has to be one of PicoRuby's built-in libraries.
  class PicoRubyCompatibility < CompatibilityScan
    # Libraries compiled into @picoruby/wasm-wasi, by require name: each
    # picoruby-<name> gem in build_config/picoruby-wasm.rb and its stdlib
    # gembox registers as <name>. PicoRuby's require answers nothing else
    # from the runtime - not even `require "enumerator"` - while the mruby
    # core gems (String/Array/Hash extensions, Math, IO, Dir, Task, eval,
    # ObjectSpace) are loaded from the start and need no require at all.
    FEATURES = %w[
      js json yaml base64 base16 rng marshal data
      indexeddb funicular markdown drb sqlite3 dfu
    ].freeze

    def target = "PicoRuby"

    private

    def provided_feature?(feature) = FEATURES.include?(feature)

    def gem_problem(gem)
      if gem.stdlib
        [:error, "Ruby standard library that PicoRuby does not have"]
      else
        [:error, "PicoRuby cannot load RubyGems gems; only its built-in libraries (#{FEATURES.first(8).join(", ")}, ...)"]
      end
    end

    def missing_stdlib_message(name)
      "require #{name.inspect}: part of CRuby's standard library, which PicoRuby does not have"
    end

    def dynamic_require_message(name)
      "#{name} with a computed name: OCRAN bundles the program's files ahead of time, so the name must be a string literal"
    end

    def check_call(node, name, args, receiver, kernel)
      case name
      when :system, :spawn, :exec, :fork
        flag(:error, node, "#{name}: there are no processes in the browser") if kernel || constant?(receiver, :Process)
      when :new, :start
        if constant?(receiver, :Thread)
          flag(:error, node, "Thread.#{name}: PicoRuby has no Thread; use Task, its cooperative tasks")
        end
      when :autoload
        flag(:error, node, "autoload is not supported by PicoRuby; require the file instead") if kernel || receiver
      when :refine, :using
        if receiver.nil? && args.size == 1 && (node.block || name == :using)
          flag(:error, node, "refinements (refine / using) are not supported by PicoRuby")
        end
      when :load
        flag(:error, node, "load: the application's files are not on PicoRuby's file system in the browser") if kernel && !args.empty?
      when :gets, :readline
        flag(:warning, node, "#{name}: the browser has no standard input") if kernel || constant?(receiver, :STDIN)
      when :force_encoding, :encode
        flag(:warning, node, "#{name}: PicoRuby strings are UTF-8 only, without CRuby's encodings")
      end
    end

    def check_constant(node)
      case node.name
      when :Ractor
        flag(:error, node, "Ractor is not supported by PicoRuby")
      when :Encoding
        flag(:warning, node, "Encoding: PicoRuby strings are UTF-8 only, without CRuby's encodings")
      end
    end

    def check_xstring(node)
      flag(:error, node, "backticks: there are no processes in the browser")
    end
  end
end
