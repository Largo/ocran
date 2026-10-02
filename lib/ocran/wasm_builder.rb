# frozen_string_literal: true
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "command_output" unless defined?(Ocran::CommandOutput)
require_relative "aot_toolchain"
require_relative "npm_package"
require_relative "wasm_compatibility"

module Ocran
  # Builds --wasm output: the application as a web page that runs it in the
  # browser on WebAssembly, written to a directory or a zip archive.
  #
  # Two runtimes:
  #
  # ruby (the default) - ruby.wasm (https://github.com/ruby/ruby.wasm),
  #   CRuby with its whole standard library compiled to WebAssembly. The
  #   application's files are packed into the interpreter's module with
  #   rbwasm (gem install ruby_wasm), at /src. Without gems that is the
  #   prebuilt interpreter from npm and a pack, which takes seconds; gems
  #   listed in the application's Gemfile need `rbwasm build`, which
  #   compiles CRuby and the gems for WebAssembly once and caches it.
  #
  # picoruby - PicoRuby (https://github.com/picoruby/picoruby), the mruby
  #   based Ruby for microcontrollers, whose WebAssembly build is 2 MB
  #   rather than 30 and needs no tool at all: its runtime comes from npm
  #   and runs the script from a <script type="text/ruby"> tag. PicoRuby has
  #   no file system holding the application in the browser, so OCRAN
  #   bundles the program's own files into one script.
  #
  # Either way the result is a static site: index.html, the runtime and the
  # application. Browsers fetch WebAssembly only over HTTP, so it has to be
  # served rather than opened as a file.
  class WasmBuilder
    include CommandOutput

    # Versions of CRuby that ruby.wasm publishes prebuilt.
    RUBY_VERSIONS = %w[4.0 3.4 3.3 3.2].freeze

    # Used when the ruby_wasm gem's own version cannot be determined. The
    # JavaScript runtime, the prebuilt interpreter and rbwasm come from the
    # same ruby.wasm release, so the gem's version picks the npm packages.
    DEFAULT_RUBY_WASM_VERSION = "2.10.1"

    PICORUBY_VERSION = ENV.fetch("OCRAN_PICORUBY_VERSION", "4.0.5")
    PICORUBY_FILES = %w[dist/init.iife.js dist/picoruby.js dist/picoruby.wasm].freeze

    MAX_OUTPUT_LINES = 60

    def initialize(option)
      @option = option
      @script = option.script
      @name = @script.basename(".*").to_s
      @output = option.wasm_output
    end

    def build
      Dir.mktmpdir("ocran-wasm") do |work|
        site = File.join(work, "site")
        FileUtils.mkdir_p(site)

        if @option.wasm_runtime == :picoruby
          build_picoruby(site)
        else
          build_ruby_wasm(work, site)
        end

        if @option.wasm_zip?
          write_zip(site)
        else
          write_directory(site)
        end
      end
    end

    private

    # --- ruby.wasm ------------------------------------------------------

    def build_ruby_wasm(work, site)
      gemfile = @option.application_gemfile
      analysis = RubyWasmCompatibility.new(@script, gemfile_gems: locked_gems(gemfile),
                                                    project_dirs: project_dirs).analyze

      rbwasm = find_rbwasm
      unless rbwasm
        error "--wasm needs rbwasm, the ruby.wasm packager from the ruby_wasm gem, which was not found."
        STDERR.puts
        STDERR.puts "Install it with:"
        STDERR.puts
        STDERR.puts "    gem install ruby_wasm"
        STDERR.puts
        STDERR.puts "(or add `gem \"ruby_wasm\"` to the Gemfile you run OCRAN under). It needs no compiler for"
        STDERR.puts "applications without gems. --wasm=picoruby needs nothing installed at all."
        STDERR.puts
        print_report(analysis, "Meanwhile, a static check of whether #{display(@script)} is likely to run on ruby.wasm:")
        raise "rbwasm is not installed"
      end

      warn_about(analysis)
      ruby_version = wasm_ruby_version
      npm_version = ruby_wasm_version
      verbose "Using rbwasm #{npm_version} at #{rbwasm.last}, Ruby #{ruby_version}"

      with_gems = needs_gems?(analysis, gemfile)
      base = if with_gems
               build_with_gems(rbwasm, gemfile, ruby_version, work, analysis)
             else
               say "Using the prebuilt ruby.wasm (Ruby #{ruby_version} with its standard library)"
               NpmPackage.fetch("@ruby/#{ruby_version}-wasm-wasi", npm_version, ["dist/ruby+stdlib.wasm"]) { |s| say s }
                         .fetch("dist/ruby+stdlib.wasm")
             end

      src = File.join(work, "src")
      main = stage_sources(src, analysis)
      say "Packing #{display(@script)} into the WebAssembly module"
      run_or_fail([*rbwasm, "pack", base, "--dir", "#{src}::/src", "-o", File.join(site, "app.wasm")],
                  "rbwasm could not pack the application", analysis)

      runtime = NpmPackage.fetch("@ruby/wasm-wasi", npm_version, ["dist/browser.umd.js"]) { |s| say s }
      FileUtils.cp(runtime.fetch("dist/browser.umd.js"), File.join(site, "browser.umd.js"))
      File.write(File.join(site, "index.html"), ruby_wasm_html("/src/#{main}", gems: with_gems))
    end

    # `rbwasm build` compiles CRuby for WebAssembly together with the gems
    # the Gemfile lists, under /bundle. Its downloads and build trees are
    # kept in OCRAN's cache, so only the first build is slow.
    def build_with_gems(rbwasm, gemfile, ruby_version, work, analysis)
      gems = analysis.gems.values.reject(&:stdlib).map(&:name)
      say "Building ruby.wasm with the gems of #{display(gemfile)} (#{gems.join(", ")})"
      say "The first build compiles CRuby for WebAssembly and takes several minutes; later builds reuse it"

      cache = File.join(cache_dir, "ruby_wasm")
      FileUtils.mkdir_p(cache)
      output = File.join(work, "ruby.wasm")
      env = { "RUBY_WASM_ROOT" => cache, "BUNDLE_GEMFILE" => gemfile.to_s,
              "RUBYOPT" => nil, "BUNDLER_SETUP" => nil, "BUNDLE_LOCKFILE" => nil }
      # rbwasm reads the bundle through Bundler only when Bundler is loaded,
      # which `bundle exec` would do - but that needs ruby_wasm in the
      # application's own Gemfile.
      command = [*rbwasm_with_bundler(rbwasm), "build", "--ruby-version", ruby_version, *@option.wasm_options, "-o", output]
      run_or_fail(command, "rbwasm could not build ruby.wasm with the application's gems", analysis,
                  env: env, chdir: File.dirname(gemfile)) do
        STDERR.puts "  - the gems have to be installed for this Ruby: run `bundle install` in #{display(File.dirname(gemfile))}"
        native = analysis.gems.values.select(&:native).map(&:name)
        unless native.empty?
          STDERR.puts "  - gems with C extensions are compiled for WASI and often fail there: #{native.join(", ")}"
        end
      end
      output
    end

    def needs_gems?(analysis, gemfile)
      gemfile && analysis.gems.values.any? { |gem| !gem.stdlib }
    end

    # Names of the gems in the application's Gemfile.lock, or nil without a
    # Gemfile. Read without Bundler, which would otherwise be packed into
    # nothing here but still pulls its settings in.
    def locked_gems(gemfile)
      return nil unless gemfile

      lockfile = Pathname("#{gemfile}.lock")
      lockfile = gemfile.dirname + "gems.locked" if gemfile.basename.to_s == "gems.rb"
      return [] unless lockfile.file?

      lockfile.read.scan(/^    ([^\s(]+) \(/).flatten.uniq
    end

    # The rbwasm command: the RBWASM environment variable, else through this
    # Ruby when the ruby_wasm gem is installed for it, else from PATH.
    def find_rbwasm
      if (explicit = ENV["RBWASM"]) && !explicit.empty?
        raise "RBWASM=#{explicit} is not an executable" unless AotToolchain.executable?(explicit)

        return [explicit]
      end
      [RbConfig.ruby, Gem.bin_path("ruby_wasm", "rbwasm")]
    rescue Gem::Exception
      path = AotToolchain.search_path("rbwasm")
      path && [path]
    end

    def rbwasm_with_bundler(rbwasm)
      rbwasm.size == 2 ? [rbwasm[0], "-rbundler", rbwasm[1]] : rbwasm
    end

    def ruby_wasm_version
      Gem::Specification.find_by_name("ruby_wasm").version.to_s
    rescue Gem::Exception
      DEFAULT_RUBY_WASM_VERSION
    end

    # The CRuby version closest to the one OCRAN runs on, so the program
    # meets the Ruby it was written for.
    def wasm_ruby_version
      if (wanted = @option.wasm_ruby)
        return wanted if RUBY_VERSIONS.include?(wanted)

        raise "ruby.wasm publishes Ruby #{RUBY_VERSIONS.join(", ")}, not #{wanted}"
      end

      host = RUBY_VERSION.split(".").first(2).join(".")
      RUBY_VERSIONS.include?(host) ? host : RUBY_VERSIONS.first
    end

    # Copies the program's files into dir, laid out relative to their
    # common directory, and returns the script's path there: the files
    # given on the command line, and the ones the program requires, which
    # the scan found since the program is not run to find them.
    def stage_sources(dir, analysis)
      root = source_root(analysis.project_files)
      (@option.source_files | analysis.project_files).each do |file|
        rel = file.relative_path_from(root)
        dest = File.join(dir, rel.to_s)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(file, dest)
      end
      @script.relative_path_from(root).to_s
    end

    def source_root(extra = [])
      dirs = (@option.source_files | extra).map(&:dirname)
      dirs.inject do |common, dir|
        common = common.parent until dir.to_s == common.to_s || dir.to_s.start_with?("#{common.to_s.chomp("/")}/")
        common
      end
    end

    # --- PicoRuby -------------------------------------------------------

    def build_picoruby(site)
      analysis = PicoRubyCompatibility.new(@script, project_dirs: project_dirs).analyze
      warn_about(analysis)

      say "Bundling #{display(@script)} for PicoRuby"
      File.write(File.join(site, script_name), bundle_sources(analysis))

      # Files given besides the code (data, images) are served next to the
      # page, where the program can fetch them through the js library.
      bundled = analysis.files.map(&:to_s)
      root = source_root
      @option.source_files.each do |file|
        next if bundled.include?(file.to_s) || file.extname == ".rb"

        dest = File.join(site, file.relative_path_from(root).to_s)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(file, dest)
      end

      runtime = NpmPackage.fetch("@picoruby/wasm-wasi", PICORUBY_VERSION, PICORUBY_FILES) { |s| say s }
      runtime.each_value { |path| FileUtils.cp(path, File.join(site, File.basename(path))) }
      File.write(File.join(site, "index.html"), picoruby_html)
    end

    # One script made of the program's own files, each placed before the
    # first file that requires it, the way Ruby would have loaded them, with
    # the requires themselves replaced by nil. Line breaks inside a replaced
    # require are kept, so each file's lines stay where they were.
    def bundle_sources(analysis)
      requires = analysis.local_requires.group_by { |r| r.from.to_s }
      order = []
      visit = lambda do |file, active|
        next if order.include?(file) || active.include?(file)

        (requires[file] || []).each { |r| visit.call(r.target.to_s, active + [file]) }
        order << file
      end
      visit.call(@script.to_s, [])

      root = source_root
      order.map do |file|
        source = File.binread(file)
        (requires[file] || []).sort_by(&:start_offset).reverse_each do |r|
          original = source.byteslice(r.start_offset...r.end_offset)
          source = source.byteslice(0, r.start_offset) + "nil" + ("\n" * original.count("\n")) +
                   source.byteslice(r.end_offset..)
        end
        source = source.force_encoding(Encoding::UTF_8)
        next source if order.size == 1

        rel = Pathname(file).relative_path_from(root)
        "# ---- #{rel} ----\n#{source.chomp}\n"
      end.join("\n")
    end

    # The bundled program is served under the script's own name, which is
    # the file name PicoRuby's error messages give.
    def script_name = "#{@name}.rb"

    # --- Output ---------------------------------------------------------

    def write_directory(site)
      @output.mkpath
      Dir.children(site).each do |entry|
        FileUtils.rm_rf(@output + entry)
        FileUtils.cp_r(File.join(site, entry), @output + entry)
      end
      finished(@output)
    end

    def write_zip(site)
      require_relative "zip_writer"

      @output.dirname.mkpath
      # An empty archive is just its end-of-central-directory record, which
      # ZipWriter appends the site to.
      File.binwrite(@output, "PK\x05\x06".b + ("\0" * 18).b)
      entries = Dir.glob("**/*", base: site).sort.reject { |rel| File.directory?(File.join(site, rel)) }.map do |rel|
        ZipWriter::Entry.new(name: rel, source: File.join(site, rel), mode: 0o644)
      end
      ZipWriter.append(@output.to_s, entries)
      finished(@output)
    end

    def finished(path)
      say "Finished building #{display(path)}"
      dir = @option.wasm_zip? ? "<unpacked folder>" : display(path)
      say "Browsers load WebAssembly only over HTTP: serve the folder and open index.html, e.g."
      say "  ruby -run -e httpd #{dir} -p 8000   (needs the webrick gem)"
      say "  python3 -m http.server -d #{dir} 8000"
    end

    # --- Diagnostics ----------------------------------------------------

    # Nothing is known to fail until the browser runs it, so what the scan
    # found is shown as a warning and the build goes on.
    def warn_about(analysis)
      return if analysis.findings.empty? || !@option.warning?

      runtime = analysis.target
      if analysis.errors.empty?
        warning "#{display(@script)} uses #{analysis.findings.size} thing(s) that may not work on #{runtime}" \
                "#{@option.verbose? ? ":" : " (--verbose lists them)"}"
        verbose analysis.report.gsub(/^(?=.)/, "  ")
      else
        warning "#{display(@script)} is unlikely to run on #{runtime} as it is; building anyway:"
        STDERR.puts analysis.report.gsub(/^(?=.)/, "  ")
      end
    end

    def print_report(analysis, heading)
      STDERR.puts heading
      STDERR.puts
      STDERR.puts analysis.report.gsub(/^(?=.)/, "  ")
    end

    def run_or_fail(command, failure, analysis, env: {}, chdir: Dir.pwd)
      verbose command.join(" ")
      output, status = Open3.capture2e(env, *command, chdir: chdir)
      return if status.success?

      lines = output.lines
      STDERR.puts "#{failure} (exit status #{status.exitstatus.inspect}):"
      STDERR.puts "  ... (#{lines.size - MAX_OUTPUT_LINES} earlier lines omitted)" if lines.size > MAX_OUTPUT_LINES
      STDERR.puts lines.last(MAX_OUTPUT_LINES).map { |l| "  #{l}" }.join
      STDERR.puts
      print_report(analysis, "What may stand in the way:") unless analysis.findings.empty?
      STDERR.puts
      STDERR.puts "Things to try:"
      yield if block_given?
      STDERR.puts "  - --wasm=picoruby runs smaller programs without any of the toolchain"
      raise failure
    end

    def project_dirs
      [@script.dirname, *@option.source_files.map(&:dirname)].uniq
    end

    def cache_dir
      base = ENV["XDG_CACHE_HOME"]
      base = File.join(Dir.home, ".cache") if base.nil? || base.empty?
      File.join(base, "ocran")
    rescue ArgumentError
      File.join(Dir.tmpdir, "ocran-cache")
    end

    # Relative to the working directory when inside it, else absolute.
    def display(path)
      rel = Pathname(path).relative_path_from(Pathname.pwd).to_s
      rel.start_with?("..") ? path.to_s : rel
    rescue ArgumentError
      path.to_s
    end

    # --- Pages ----------------------------------------------------------

    def ruby_wasm_html(main, gems:)
      setup = gems ? %(require "/bundle/setup"\n) : ""
      ruby = <<~RUBY
        #{setup}$0 = #{main.inspect}
        Dir.chdir(File.dirname($0))
        load $0
      RUBY
      page(<<~JS, newline: false)
        <script src="browser.umd.js"></script>
        <script>
          (async () => {
            try {
              const { DefaultRubyVM } = window["ruby-wasm-wasi"];
              const module = await WebAssembly.compileStreaming(fetch("app.wasm"));
              const { vm } = await DefaultRubyVM(module);
              ocranStarted();
              await vm.evalAsync(#{ruby.to_json});
            } catch (error) {
              ocranFailed(error);
            }
          })();
        </script>
      JS
    end

    def picoruby_html
      page(<<~JS, newline: true)
        <script type="text/ruby" src="#{script_name}"></script>
        <script src="init.iife.js"></script>
        <script>
          const ocranWait = setInterval(() => {
            if (window.picorubyModule) { clearInterval(ocranWait); ocranStarted(); }
          }, 50);
        </script>
      JS
    end

    # The page around a runtime: a status line while it loads, and the
    # program's standard output and errors mirrored from the console onto
    # the page, where a terminal program's output is expected. newline:
    # whether each console call is a line (PicoRuby) rather than a chunk of
    # output that brings its own line breaks (ruby.wasm).
    def page(runtime, newline:)
      title = @name.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{title}</title>
          <style>
            :root { color-scheme: light dark; }
            body { margin: 0; padding: 16px; font-family: system-ui, sans-serif; }
            #ocran-status { opacity: 0.7; }
            #ocran-output { margin: 0; white-space: pre-wrap; font-family: ui-monospace, Menlo, Consolas, monospace; }
            #ocran-output .stderr { color: #d33; }
          </style>
        </head>
        <body>
          <div id="ocran-status">Loading #{title}...</div>
          <pre id="ocran-output"></pre>
          <script>
            const ocranOutput = document.getElementById("ocran-output");
            const ocranAppend = (text, stream) => {
              const span = document.createElement("span");
              if (stream) span.className = stream;
              span.textContent = #{newline ? 'text + "\\n"' : "text"};
              ocranOutput.appendChild(span);
            };
            const ocranConsole = {};
            const ocranStarted = () => document.getElementById("ocran-status")?.remove();
            const ocranFailed = (error) => {
              ocranStarted();
              ocranAppend(String(error && error.message || error) + #{newline ? '""' : '"\\n"'}, "stderr");
              ocranConsole.error(error);
            };
            for (const [name, stream] of [["log", null], ["info", null], ["warn", "stderr"], ["error", "stderr"]]) {
              const original = ocranConsole[name] = console[name].bind(console);
              console[name] = (...args) => {
                original(...args);
                ocranAppend(args.map(String).join(" "), stream);
              };
            }
          </script>
        #{runtime.gsub(/^/, "  ").rstrip}
        </body>
        </html>
      HTML
    end
  end
end
