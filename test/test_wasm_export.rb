# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "bundler"
require_relative "../lib/ocran/wasm_compatibility"

# Tests for --wasm. The runtimes come from npm; these tests put stand-in
# files into OCRAN's npm cache (XDG_CACHE_HOME) and a stand-in rbwasm in
# RBWASM, so they run offline and without ruby_wasm installed. Whether the
# exported page really runs is checked by hand in a browser.
class TestWasmExport < Minitest::Test
  OcranRoot = File.expand_path("..", __dir__)
  FixturePath = File.join(__dir__, "fixtures")
  Ocran = File.join(OcranRoot, "exe", "ocran")

  def setup
    @tmp = Dir.mktmpdir(".ocrantest-wasm-")
    @cache = File.join(@tmp, "cache")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def posix_only
    skip "the stand-in rbwasm is a shell script" if Gem.win_platform?
  end

  def ocran(dir, *args, env: {})
    env = { "XDG_CACHE_HOME" => @cache }.merge(env)
    Bundler.with_original_env do
      Open3.capture2e(env, RbConfig.ruby, Ocran, *args, chdir: dir)
    end
  end

  def fixture(name)
    FileUtils.cp_r(File.join(FixturePath, name), @tmp)
    File.join(@tmp, name)
  end

  # Fills the npm cache the way NpmPackage leaves it.
  def cache_npm(name, version, files)
    dir = File.join(@cache, "ocran", "npm", name.delete_prefix("@").tr("/", "-"), version)
    files.each do |file, content|
      path = File.join(dir, file)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end

  def cache_picoruby
    cache_npm("@picoruby/wasm-wasi", "4.0.5",
              "dist/init.iife.js" => "// init", "dist/picoruby.js" => "// js", "dist/picoruby.wasm" => "wasm")
  end

  def scan(klass, source, files = {}, **options)
    files.each do |name, content|
      FileUtils.mkdir_p(File.dirname(File.join(@tmp, name)))
      File.write(File.join(@tmp, name), content)
    end
    File.write(File.join(@tmp, "app.rb"), source)
    klass.new(File.join(@tmp, "app.rb"), **options).analyze
  end

  def test_ruby_wasm_scan_flags_platform_gaps
    analysis = scan(::Ocran::RubyWasmCompatibility, <<~RUBY, gemfile_gems: [])
      require "json"
      require "net/http"
      system("ls")
      `date`
      Thread.new { }
      name = gets
    RUBY
    report = analysis.report

    assert analysis.errors.empty?, report
    refute_match(/json/, report) # the standard library is in ruby.wasm
    assert_match(/app\.rb:2: require "net\/http": WebAssembly in the browser has no sockets/, report)
    assert_match(/app\.rb:3: system: WebAssembly has no processes/, report)
    assert_match(/app\.rb:4: backticks/, report)
    assert_match(/app\.rb:5: Thread\.new: ruby\.wasm has no threads/, report)
    assert_match(/app\.rb:6: gets: the browser has no standard input/, report)
  end

  def test_ruby_wasm_scan_requires_gems_in_gemfile
    spec = Gem::Specification.find { |s| !s.default_gem? && s.extensions.empty? && !s.require_paths.empty? }
    skip "no pure-Ruby gem is installed" unless spec
    feature = Dir.glob("*.rb", base: spec.full_require_paths.first).map { |f| f.delete_suffix(".rb") }
                 .find { |f| Gem::Specification.find_by_path(f) == spec }
    skip "#{spec.name} has no top-level feature" unless feature

    without = scan(::Ocran::RubyWasmCompatibility, "require #{feature.inspect}\n", gemfile_gems: nil)
    assert_match(/the application has no Gemfile/, without.report)

    unlisted = scan(::Ocran::RubyWasmCompatibility, "require #{feature.inspect}\n", gemfile_gems: ["other"])
    assert_match(/not in the application's Gemfile\.lock/, unlisted.report)

    listed = scan(::Ocran::RubyWasmCompatibility, "require #{feature.inspect}\n", gemfile_gems: [spec.name])
    refute_match(/Gemfile/, listed.report)
  end

  def test_picoruby_scan
    analysis = scan(::Ocran::PicoRubyCompatibility, <<~RUBY, { "lib/helper.rb" => "X = 1\n" })
      require "json"
      require "js"
      require "optparse"
      require "helper"
      Thread.new { }
      autoload :Foo, "foo"
    RUBY
    report = analysis.report

    refute_match(/"json"|"js"/, report)
    assert_match(/app\.rb:3: require "optparse": .*standard library.*PicoRuby does not have/, report)
    assert_match(/app\.rb:5: Thread\.new: PicoRuby has no Thread; use Task/, report)
    assert_match(/app\.rb:6: autoload is not supported/, report)
    assert_equal [File.join(@tmp, "lib", "helper.rb")], analysis.local_requires.map { |r| r.target.to_s }
  end

  def test_picoruby_export_bundles_program
    dir = fixture("wasm")
    cache_picoruby
    out, status = ocran(dir, "wasm.rb", "--picoruby")
    assert status.success?, out

    site = File.join(dir, "wasm-picoruby")
    %w[index.html wasm.rb init.iife.js picoruby.js picoruby.wasm].each do |file|
      assert File.file?(File.join(site, file)), "#{file} missing:\n#{out}"
    end
    bundle = File.read(File.join(site, "wasm.rb"))
    # greeter.rb comes first, and the require_relative is gone.
    assert_operator bundle.index("class Greeter"), :<, bundle.index("Greeter.new")
    refute_match(/require_relative/, bundle)
    html = File.read(File.join(site, "index.html"))
    assert_match(%r{<script type="text/ruby" src="wasm.rb"></script>}, html)
    assert_match(/init\.iife\.js/, html)
  end

  def test_picoruby_export_to_zip
    dir = fixture("wasm")
    cache_picoruby
    out, status = ocran(dir, "wasm.rb", "--wasm=picoruby", "--output", "site.zip")
    assert status.success?, out

    zip = File.binread(File.join(dir, "site.zip"))
    assert zip.start_with?("PK\x03\x04".b), "not a zip archive"
    %w[index.html wasm.rb picoruby.wasm].each { |name| assert_includes zip, name }
  end

  # A stand-in for rbwasm: `pack` logs its arguments and copies its input
  # module to the -o path.
  def fake_rbwasm
    path = File.join(@tmp, "rbwasm")
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$@" > "#{@tmp}/rbwasm-args"
      input="$2"
      while [ $# -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift; fi
        shift
      done
      cp "$input" "$out"
    SH
    File.chmod(0o755, path)
    path
  end

  def test_ruby_wasm_export_packs_sources
    posix_only
    dir = fixture("wasm")
    version = RUBY_VERSION.split(".").first(2).join(".")
    version = "4.0" unless %w[4.0 3.4 3.3 3.2].include?(version)
    ruby_wasm = begin
      Gem::Specification.find_by_name("ruby_wasm").version.to_s
    rescue Gem::LoadError, Gem::Exception
      "2.10.1"
    end
    cache_npm("@ruby/#{version}-wasm-wasi", ruby_wasm, "dist/ruby+stdlib.wasm" => "prebuilt ruby")
    cache_npm("@ruby/wasm-wasi", ruby_wasm, "dist/browser.umd.js" => "// umd")

    out, status = ocran(dir, "wasm.rb", "--wasm", "--output-dir", "site", env: { "RBWASM" => fake_rbwasm })
    assert status.success?, out

    site = File.join(dir, "site")
    assert_equal "prebuilt ruby", File.read(File.join(site, "app.wasm"))
    assert File.file?(File.join(site, "browser.umd.js"))
    args = File.read(File.join(@tmp, "rbwasm-args")).lines(chomp: true)
    assert_equal "pack", args.first
    assert_includes args, "--dir"
    src = args[args.index("--dir") + 1].split("::")
    assert_equal "/src", src.last
    html = File.read(File.join(site, "index.html"))
    assert_match(/DefaultRubyVM/, html)
    assert_match(%r{/src/wasm\.rb}, html)
    refute_match(%r{/bundle/setup}, html)
  end

  def test_wasm_option_validation
    dir = fixture("wasm")
    out, status = ocran(dir, "wasm.rb", "--wasm=jruby")
    refute status.success?
    assert_match(/Unknown --wasm runtime "jruby"/, out)

    out, status = ocran(dir, "wasm.rb", "--wasm", "--spinel")
    refute status.success?
    assert_match(/cannot be used with --spinel/, out)
  end
end
