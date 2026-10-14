# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "json"
require "digest"
require "zlib"
require_relative "../lib/ocran/static_runtime_builder"

# Unit tests for Ocran::StaticRuntimeBuilder (--static-runtime) against a made-up
# runtime directory: how the build host's layout is mapped onto the
# runtime, what ends up in ocran/config.rb, and the archive itself.
class TestStaticRuntimeBuilder < Minitest::Test
  HOST_API = "4.0.0"
  HOST_ARCH = "x86_64-linux"

  def setup
    @dir = Dir.mktmpdir
    @runtime_dir = File.join(@dir, "runtime")
    @host = File.join(@dir, "host")
    write_runtime
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # A runtime with a tiny "executable", a standard library, a bundled gem
  # with a C extension (fiddle) and two default gems (psych needs stringio).
  def write_runtime
    exe = runtime_file("ocran-runtime.exe", "MZ" + "\0" * 0x3a + [0x40].pack("V") + "PE\0\0" + "\0" * 200)
    runtime_file("lib/ruby/4.0.0/json.rb", "# runtime json")
    runtime_file("lib/ruby/4.0.0/psych.rb", "# runtime psych")
    runtime_file("lib/ruby/4.0.0/x64-mingw-ucrt/rbconfig.rb", "# runtime rbconfig")
    runtime_file("lib/ruby/gems/4.0.0/specifications/fiddle-1.1.8.gemspec", gemspec("fiddle", "1.1.8", extensions: true))
    runtime_file("lib/ruby/gems/4.0.0/gems/fiddle-1.1.8/lib/fiddle.rb", "# runtime fiddle")
    runtime_file("lib/ruby/gems/4.0.0/gems/fiddle-1.1.8/lib/fiddle.so", "ELF")
    runtime_file("lib/ruby/gems/4.0.0/specifications/default/psych-5.3.1.gemspec",
                 gemspec("psych", "5.3.1", dependencies: ["stringio"]))
    runtime_file("lib/ruby/gems/4.0.0/specifications/default/stringio-3.2.0.gemspec", gemspec("stringio", "3.2.0"))
    info = {
      "format" => 1, "ruby_version" => "4.0.6", "ruby_api_version" => "4.0.0", "arch" => "x64-mingw-ucrt",
      "executable" => "ocran-runtime.exe", "executable_sha256" => Digest::SHA256.file(exe).hexdigest,
      "load_path" => ["lib/ruby/site_ruby/4.0.0", "lib/ruby/4.0.0", "lib/ruby/4.0.0/x64-mingw-ucrt"],
      "gem_dir" => "lib/ruby/gems/4.0.0", "gem_platform" => "x64-mingw-ucrt",
      "extension_api_version" => "4.0.0-static",
      "static_features" => ["json/ext/parser", "fiddle", "enc/utf_16le", "stringio"],
      "gems" => {
        "fiddle" => "specifications/fiddle-1.1.8.gemspec",
        "psych" => "specifications/default/psych-5.3.1.gemspec",
        "stringio" => "specifications/default/stringio-3.2.0.gemspec",
      },
    }
    File.write(File.join(@runtime_dir, "runtime.json"), JSON.generate(info))
  end

  def gemspec(name, version, extensions: false, dependencies: [])
    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.summary = name
      s.authors = ["x"]
      s.files = []
      s.extensions = ["ext/#{name}/extconf.rb"] if extensions
      dependencies.each { |d| s.add_runtime_dependency(d) }
    end
    spec.to_ruby
  end

  def runtime_file(relative, data)
    path = File.join(@runtime_dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, data)
    path
  end

  def host_file(relative, data = "# host #{relative}")
    path = File.join(@host, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, data)
    path
  end

  def runtime
    Ocran::StaticRuntime.load(@runtime_dir)
  end

  def build(output = File.join(@dir, "app.exe"), **options, &block)
    builder = Ocran::StaticRuntimeBuilder.new(output, runtime: runtime, host_ruby_api_version: HOST_API,
                                                  host_arch: HOST_ARCH, **options) do |b|
      block&.call(b)
      b.exec("bin/ruby.exe", "src/app.rb", "a b") unless b.instance_variable_get(:@exec)
    end
    [builder, read_archive(output)]
  end

  # Archive members by name, read the way the runtime's stage 0 does: from
  # the end-of-central-directory record, with offsets from the file start.
  def read_archive(path)
    data = File.binread(path)
    eocd = data.rindex("PK\x05\x06".b)
    count, cd_size, cd_offset = data.byteslice(eocd + 10, 10).unpack("vVV")
    members = {}
    pos = cd_offset
    count.times do
      _, _, _, _, method, _, _, _, csize, _, nlen, xlen, clen, _, _, _, offset =
        data.byteslice(pos, 46).unpack("VvvvvvvVVVvvvvvVV")
      name = data.byteslice(pos + 46, nlen)
      lnlen, lxlen = data.byteslice(offset + 26, 4).unpack("vv")
      body = data.byteslice(offset + 30 + lnlen + lxlen, csize)
      members[name] = method == 8 ? Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(body) : body
      pos += 46 + nlen + xlen + clen
    end
    assert_equal cd_offset + cd_size, eocd
    members
  end

  def config(members)
    eval(members.fetch("ocran/config.rb")) # rubocop:disable Security/Eval
  end

  def test_output_is_the_runtime_followed_by_the_archive
    _, members = build { |b| b.cp(host_file("src/app.rb"), "src/app.rb") }
    exe = File.binread(File.join(@runtime_dir, "ocran-runtime.exe"))
    assert File.binread(File.join(@dir, "app.exe")).start_with?(exe)
    assert_equal File.binread(Ocran::StaticRuntimeBuilder::BOOT_SCRIPT), members.fetch("ocran/boot.rb")
    assert_equal "# host src/app.rb", members.fetch("src/app.rb")
  end

  def test_standard_library_comes_from_the_runtime
    _, members = build do |b|
      b.cp(host_file("lib/ruby/4.0.0/json.rb"), "lib/ruby/4.0.0/json.rb")
      b.cp(host_file("lib/ruby/4.0.0/x86_64-linux/rbconfig.rb"), "lib/ruby/4.0.0/x86_64-linux/rbconfig.rb")
    end
    assert_equal "# runtime json", members.fetch("lib/ruby/4.0.0/json.rb")
    # The host's architecture directory maps onto the runtime's.
    assert_equal "# runtime rbconfig", members.fetch("lib/ruby/4.0.0/x64-mingw-ucrt/rbconfig.rb")
    refute members.key?("lib/ruby/4.0.0/x86_64-linux/rbconfig.rb")
  end

  def test_host_only_standard_library_files_are_left_out
    builder, members = build { |b| b.cp(host_file("lib/ruby/4.0.0/hostonly.rb"), "lib/ruby/4.0.0/hostonly.rb") }
    refute members.key?("lib/ruby/4.0.0/hostonly.rb")
    assert_includes builder.skipped[:not_in_runtime_stdlib], "lib/ruby/4.0.0/hostonly.rb"
  end

  def test_host_interpreter_files_are_not_packed
    _, members = build do |b|
      b.cp(host_file("bin/ruby.exe"), "bin/ruby.exe")
      b.cp(host_file("bin/libssl-3-x64.dll"), "bin/libssl-3-x64.dll")
      b.cp(host_file("lib/ruby/4.0.0/x86_64-linux/openssl.so-assembly.manifest"),
           "lib/ruby/4.0.0/x86_64-linux/openssl.so-assembly.manifest")
      b.cp(host_file("lib/ruby/site_ruby/4.0.0/ruby_installer/runtime.rb"),
           "lib/ruby/site_ruby/4.0.0/ruby_installer/runtime.rb")
      b.cp(host_file("lib/ruby/site_ruby/4.0.0/rubygems/defaults/operating_system.rb"),
           "lib/ruby/site_ruby/4.0.0/rubygems/defaults/operating_system.rb")
    end
    assert_empty members.keys.grep(%r{\Abin/|\.dll\z|\.manifest\z|ruby_installer|operating_system})
  end

  def test_linked_in_extensions_are_skipped_others_fail_the_build
    builder, = build do |b|
      b.cp(host_file("lib/ruby/4.0.0/x86_64-linux/json/ext/parser.so"), "lib/ruby/4.0.0/x86_64-linux/json/ext/parser.so")
      b.cp(host_file("lib/ruby/4.0.0/x86_64-linux/enc/utf_16le.so"), "lib/ruby/4.0.0/x86_64-linux/enc/utf_16le.so")
    end
    assert_equal 2, builder.skipped[:static_extension].size

    error = assert_raises(RuntimeError) do
      build { |b| b.cp(host_file("gems/gems/nokogiri-1.18.0/lib/nokogiri.so"), "gems/gems/nokogiri-1.18.0/lib/nokogiri.so") }
    end
    assert_match %r{gems/gems/nokogiri-1\.18\.0/lib/nokogiri\.so}, error.message
  end

  def test_gems_the_runtime_ships_are_packed_from_the_runtime
    _, members = build do |b|
      b.cp(host_file("lib/ruby/gems/4.0.0/specifications/fiddle-1.1.8.gemspec"),
           "lib/ruby/gems/4.0.0/specifications/fiddle-1.1.8.gemspec")
      b.cp(host_file("lib/ruby/gems/4.0.0/gems/fiddle-1.1.8/lib/fiddle.rb"),
           "lib/ruby/gems/4.0.0/gems/fiddle-1.1.8/lib/fiddle.rb")
    end
    assert_equal "# runtime fiddle", members.fetch("lib/ruby/gems/4.0.0/gems/fiddle-1.1.8/lib/fiddle.rb")
    assert_match(/fiddle/, members.fetch("lib/ruby/gems/4.0.0/specifications/fiddle-1.1.8.gemspec"))
    # Linked in: the runtime gem's own binary is not packed, but RubyGems
    # gets the marker it requires before activating a gem with extensions.
    refute members.key?("lib/ruby/gems/4.0.0/gems/fiddle-1.1.8/lib/fiddle.so")
    assert_equal "", members.fetch("lib/ruby/gems/4.0.0/extensions/x64-mingw-ucrt/4.0.0-static/fiddle-1.1.8/gem.build_complete")
  end

  def test_newer_host_version_of_a_default_gem_maps_to_the_runtime_stdlib
    _, members = build do |b|
      b.cp(host_file("lib/ruby/gems/4.0.0/specifications/psych-5.4.0.gemspec"),
           "lib/ruby/gems/4.0.0/specifications/psych-5.4.0.gemspec")
      b.cp(host_file("lib/ruby/gems/4.0.0/gems/psych-5.4.0/lib/psych.rb"),
           "lib/ruby/gems/4.0.0/gems/psych-5.4.0/lib/psych.rb")
    end
    assert_equal "# runtime psych", members.fetch("lib/ruby/4.0.0/psych.rb")
    refute members.keys.any? { |name| name.include?("psych-5.4.0") }
    assert members.key?("lib/ruby/gems/4.0.0/specifications/default/psych-5.3.1.gemspec")
    # Activating psych activates its dependencies, whose specs come along.
    assert members.key?("lib/ruby/gems/4.0.0/specifications/default/stringio-3.2.0.gemspec")
  end

  def test_config_translates_the_extraction_layout
    _, members = build do |b|
      b.cp(host_file("src/app.rb"), "src/app.rb")
      b.export("RUBYLIB", ["|/src/lib", "|/lib/ruby/4.0.0/x86_64-linux"].join(File::PATH_SEPARATOR))
      b.export("GEM_PATH", ["|/gems", "|/lib/ruby/gems/4.0.0"].join(File::PATH_SEPARATOR))
      b.export("SSL_CERT_FILE", "|/ssl/cert.pem")
      b.export("APP_DATA", "|/data")
      b.export("LD_LIBRARY_PATH", "|/bin")
      b.export("RUBYOPT", "-I|/src/vendor -rjson -W0")
      b.exec("bin/ruby.exe", "src/app.rb", "|/data.txt")
    end
    cfg = config(members)
    assert_equal "src/app.rb", cfg[:main]
    assert_equal ["<ROOT>/data.txt"], cfg[:argv]
    # The host's stdlib directories give way to the runtime's load path.
    assert_equal ["src/lib", "lib/ruby/site_ruby/4.0.0", "lib/ruby/4.0.0", "lib/ruby/4.0.0/x64-mingw-ucrt"], cfg[:load_path]
    # Joined with the target's separator, whatever the build host uses.
    assert_equal "<ROOT>/gems;<ROOT>/lib/ruby/gems/4.0.0", cfg[:env]["GEM_PATH"]
    assert_equal "<ROOT>/data", cfg[:env]["APP_DATA"]
    # OpenSSL's C code cannot read inside the archive (it uses the Windows store).
    refute cfg[:env].key?("SSL_CERT_FILE")
    refute cfg[:env].key?("LD_LIBRARY_PATH")
    assert_equal ["<ROOT>/src/vendor"], cfg[:rubyopt_includes]
    assert_equal ["json"], cfg[:rubyopt_requires]
  end

  # A precompiled platform gem's packed copy becomes a platform "ruby"
  # gem, and the binaries it carries for its platform are dropped.
  def test_platform_gem_is_packed_as_a_ruby_platform_gem
    spec = Gem::Specification.new do |s|
      s.name = "tds"
      s.version = "1.0"
      s.platform = "x86_64-linux-gnu"
      s.summary = "x"
      s.authors = ["x"]
    end
    elf = host_file("gems/gems/tds-1.0-x86_64-linux-gnu/ports/lib/libsybdb.so.5", "\x7FELF....")
    rb = host_file("gems/gems/tds-1.0-x86_64-linux-gnu/lib/tds.rb", "# tds")
    builder = Ocran::StaticRuntimeBuilder.allocate
    builder.instance_variable_set(:@entries, {
      "gems/specifications/tds-1.0-x86_64-linux-gnu.gemspec" => Pathname(host_file("spec", "x")),
      "gems/gems/tds-1.0-x86_64-linux-gnu/lib/tds.rb" => Pathname(rb),
      "gems/gems/tds-1.0-x86_64-linux-gnu/ports/lib/libsybdb.so.5" => Pathname(elf),
    })
    builder.instance_variable_set(:@renamed_gems, {})
    builder.instance_variable_set(:@skipped, Hash.new { |h, k| h[k] = [] })
    builder.instance_variable_set(:@data_size, 0)
    builder.send(:use_as_ruby_platform_gem, spec, @dir)
    entries = builder.instance_variable_get(:@entries)
    assert_equal ["gems/gems/tds-1.0/lib/tds.rb", "gems/specifications/tds-1.0.gemspec"], entries.keys.sort
    assert_match(/s\.name = "tds"/, File.read(entries["gems/specifications/tds-1.0.gemspec"]))
    refute_match(/x86_64-linux/, File.read(entries["gems/specifications/tds-1.0.gemspec"]))
  end

  def linux_runtime!
    info = JSON.parse(File.read(File.join(@runtime_dir, "runtime.json")))
    exe = File.join(@runtime_dir, "ocran-runtime")
    File.rename(File.join(@runtime_dir, "ocran-runtime.exe"), exe)
    info.merge!("os" => "linux", "arch" => "x86_64-linux-musl", "executable" => "ocran-runtime")
    File.write(File.join(@runtime_dir, "runtime.json"), JSON.generate(info))
  end

  def test_linux_runtime_joins_paths_with_colons_and_skips_windows_parts
    linux_runtime!
    runtime_file("lib/ruby/4.0.0/win32/registry.rb", "# win32")
    _, members = build do |b|
      b.cp(host_file("src/app.rb"), "src/app.rb")
      b.export("GEM_PATH", ["|/gems", "|/lib/ruby/gems/4.0.0"].join(File::PATH_SEPARATOR))
    end
    assert_equal "<ROOT>/gems:<ROOT>/lib/ruby/gems/4.0.0", config(members)[:env]["GEM_PATH"]
    refute members.key?("lib/ruby/4.0.0/win32/registry.rb")
  end

  def test_windows_only_options_are_refused_for_a_linux_runtime
    linux_runtime!
    error = assert_raises(RuntimeError) { build(windowed: true) { |b| b.cp(host_file("src/app.rb"), "src/app.rb") } }
    assert_match(/--windows applies to Windows runtimes/, error.message)
    error = assert_raises(RuntimeError) do
      build(resources: { icon_path: "app.ico" }) { |b| b.cp(host_file("src/app.rb"), "src/app.rb") }
    end
    assert_match(/--icon and the version-resource options apply to Windows runtimes/, error.message)
    error = assert_raises(RuntimeError) { build(dlls: ["sybdb"]) { |b| b.cp(host_file("src/app.rb"), "src/app.rb") } }
    assert_match(/fully static and cannot load shared libraries/, error.message)
  end

  def test_manifest_lists_every_file_with_its_hash
    _, members = build { |b| b.cp(host_file("src/app.rb"), "src/app.rb") }
    manifest = members.fetch("ocran/manifest.sha256")
    assert_includes manifest, "#{Digest::SHA256.hexdigest("# host src/app.rb")}  src/app.rb"
    assert_includes manifest, "#{Digest::SHA256.hexdigest(members.fetch("ocran/boot.rb"))}  ocran/boot.rb"
    assert_includes manifest, Digest::SHA256.file(File.join(@runtime_dir, "ocran-runtime.exe")).hexdigest
  end

  def test_packing_twice_gives_the_same_bytes
    first = File.join(@dir, "one.exe")
    second = File.join(@dir, "two.exe")
    source = host_file("src/app.rb")
    build(first) { |b| b.cp(source, "src/app.rb") }
    File.utime(Time.now, Time.now - 3600, source)
    build(second) { |b| b.cp(source, "src/app.rb") }
    assert_equal File.binread(first), File.binread(second)
  end

  def test_failed_packaging_leaves_no_executable
    output = File.join(@dir, "broken.exe")
    error = assert_raises(RuntimeError) do
      build(output, resources: { icon_path: File.join(@dir, "missing.ico") }) { |b| b.cp(host_file("src/app.rb"), "src/app.rb") }
    end
    assert_match(/missing\.ico not found/, error.message)
    refute File.exist?(output), "a runtime copy without its archive was left behind"
  end

  def test_runtime_executable_must_match_runtime_json
    File.binwrite(File.join(@runtime_dir, "ocran-runtime.exe"), "MZ tampered")
    error = assert_raises(RuntimeError) { runtime.verify! }
    assert_match(/does not match its runtime\.json/, error.message)
  end

  def test_windows_option_switches_the_subsystem_to_gui
    output = File.join(@dir, "gui.exe")
    build(output, windowed: true) { |b| b.cp(host_file("src/app.rb"), "src/app.rb") }
    assert_equal 2, File.binread(output, 2, 0x40 + 24 + 68).unpack1("v")
  end
end
