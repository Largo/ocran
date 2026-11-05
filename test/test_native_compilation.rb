# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "bundler"
require_relative "../lib/ocran/aot_toolchain"
require_relative "../lib/ocran/spinel_compatibility"

# Tests for --spinel and --roundhouse. The compilers are stood in for by
# small shell scripts, so these run without Spinel or Roundhouse installed;
# test_spinel_end_to_end uses the real Spinel when one is found.
class TestNativeCompilation < Minitest::Test
  OcranRoot = File.expand_path("..", __dir__)
  FixturePath = File.join(__dir__, "fixtures")
  Ocran = File.join(OcranRoot, "exe", "ocran")

  def setup
    @tmp = Dir.mktmpdir(".ocrantest-native-")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def posix_only
    skip "the stand-in compilers are shell scripts" if Gem.win_platform?
  end

  # Runs OCRAN in dir with the given extra environment, outside any bundle.
  def ocran(dir, *args, env: {})
    Bundler.with_original_env do
      Open3.capture2e(env, RbConfig.ruby, Ocran, *args, chdir: dir)
    end
  end

  def fixture(name)
    FileUtils.cp_r(File.join(FixturePath, name), @tmp)
    File.join(@tmp, name)
  end

  def write_script(path, body)
    File.write(path, "#!/bin/sh\n#{body}")
    File.chmod(0o755, path)
    path
  end

  # A stand-in spinel that logs its arguments and writes a shell script to
  # the -o path, or fails like a compile error when FAKE_SPINEL_FAIL is set.
  def fake_spinel
    FileUtils.mkdir_p(File.join(@tmp, "bin"))
    write_script(File.join(@tmp, "bin", "spinel"), <<~SH)
      [ "$1" = "--version" ] && { echo "spinel 0.0 (stand-in)"; exit 0; }
      printf '%s\\n' "$@" > "#{@tmp}/spinel-args"
      if [ -n "$FAKE_SPINEL_FAIL" ]; then
        echo "spinel: cannot compile: eval is not supported" >&2
        exit 1
      fi
      while [ $# -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift; fi
        shift
      done
      printf '#!/bin/sh\\necho compiled\\n' > "$out"
      chmod +x "$out"
    SH
  end

  def test_compatibility_report_on_compatible_program
    dir = fixture("spinel")
    analysis = ::Ocran::SpinelCompatibility.new(File.join(dir, "spinel.rb")).analyze

    assert analysis.clean?, analysis.report
    assert_empty analysis.findings
    # The program's own lib/ is a -I root, so Spinel finds require "shout".
    assert_includes analysis.include_dirs, File.join(dir, "lib")
    assert_equal %w[spinel.rb greeting.rb lib/shout.rb].sort,
                 analysis.files.map { |f| f.relative_path_from(Pathname(dir)).to_s }.sort
  end

  def test_compatibility_report_on_incompatible_program
    dir = fixture("spinel_incompatible")
    analysis = ::Ocran::SpinelCompatibility.new(File.join(dir, "spinel_incompatible.rb")).analyze
    report = analysis.report

    refute analysis.clean?
    assert_match(/spinel_incompatible\.rb:1: require "no_such_library_anywhere": not a Spinel library/, report)
    assert_match(/spinel_incompatible\.rb:4: eval of a string is not supported/, report)
    assert_match(/dynamic\.rb:2: method_missing is never dispatched/, report)
    # The loop over a literal list on line 6 is expanded by Spinel; the
    # names on line 7 exist only at run time.
    refute_match(/dynamic\.rb:6:/, report)
    assert_match(/error: dynamic\.rb:7: define_method with a name computed at run time is refused/, report)
  end

  # Constructs Spinel compiles are not reported; the forms it refuses are.
  def test_compatibility_follows_spinels_subset
    File.write(File.join(@tmp, "app.rb"), <<~'RUBY')
      require "date"
      require "rbconfig"
      class Base; end
      Err = Class.new(StandardError)
      Foo = Class.new(Base) { def hi = 1 }
      Point = Class.new(Struct.new(:x, :y))
      base = Base
      Bad = Class.new(base)
      class Base
        class_eval "def lit = 1"
        class_eval <<~SRC
          def heredoc = 2
        SRC
        n = "x"
        class_eval "def #{n} = 3"
        class_eval(n)
      end
      Base.instance_eval("1")
    RUBY
    findings = ::Ocran::SpinelCompatibility.new(File.join(@tmp, "app.rb")).analyze.findings
    by_line = findings.to_h { |f| [f.line, f] }

    assert_equal [8, 15, 16, 18], by_line.keys.sort, findings.map(&:message).join("\n")
    assert_equal :error, by_line[8].severity
    assert_match(/Class.new with a superclass computed at run time/, by_line[8].message)
    assert_equal :warning, by_line[15].severity
    assert_equal :error, by_line[16].severity
    assert_match(/instance_eval with a string/, by_line[18].message)
  end

  def test_define_method_names
    File.write(File.join(@tmp, "app.rb"), <<~'RUBY')
      NAMES = %i[a b]
      class K
        %w[x y].each { |n| define_method("#{n}=") { |v| v } }
        NAMES.each { |n| define_method(n) { 1 } }
        NAMES.each { |n| define_method(n.to_s + "?") { 1 } }
        def self.flag(name) = define_method("#{name}?") { true }
        name = ENV["X"]
        define_method(name) { 1 }
        [1].map(&:to_s).each { |n| define_method(n) { n } }
      end
    RUBY
    findings = ::Ocran::SpinelCompatibility.new(File.join(@tmp, "app.rb")).analyze.findings
    severities = findings.to_h { |f| [f.line, f.severity] }

    assert_equal({ 5 => :warning, 6 => :warning, 8 => :error, 9 => :error }, severities,
                 findings.map(&:message).join("\n"))
  end

  def test_features_read_from_packages_dir
    packages = File.join(@tmp, "packages")
    %w[shellwords/shellwords.rb net/net/smtp.rb racc/ext/cparse/extconf.rb racc/test/t.rb].each do |rel|
      FileUtils.mkdir_p(File.dirname(File.join(packages, rel)))
      File.write(File.join(packages, rel), "")
    end
    File.write(File.join(@tmp, "app.rb"), %(require "shellwords"\nrequire "net/smtp"\nrequire "ext/cparse/extconf"\n))
    findings = ::Ocran::SpinelCompatibility.new(File.join(@tmp, "app.rb"), packages_dir: packages).analyze.findings

    assert_equal [3], findings.map(&:line)
  end

  def test_compatibility_report_names_native_gems
    # Any installed gem with a C extension will do, except the ones whose
    # library Spinel provides itself (bigdecimal, json, ...).
    spinel_provides = ::Ocran::SpinelCompatibility::FALLBACK_FEATURES +
                      ::Ocran::SpinelCompatibility::NATIVE_FEATURES
    feature = nil
    spec = Gem::Specification.find do |s|
      next false if s.default_gem? || s.extensions.empty? || s.require_paths.empty?

      feature = Dir.glob("*.rb", base: s.full_require_paths.first).map { |f| f.delete_suffix(".rb") }
                   .find { |f| !spinel_provides.include?(f) && Gem::Specification.find_by_path(f) == s }
    end
    skip "no gem with a C extension is installed" unless spec

    File.write(File.join(@tmp, "app.rb"), "require #{feature.inspect}\n")
    analysis = ::Ocran::SpinelCompatibility.new(File.join(@tmp, "app.rb")).analyze

    gem = analysis.gems.values.find { |g| g.native }
    assert gem, analysis.report
    assert_match(/has a C extension, which Spinel cannot compile/, analysis.report)
    assert_includes analysis.problem_gems.map(&:name), gem.name
  end

  def test_toolchain_lookup
    posix_only
    tool = write_script(File.join(@tmp, "spinel"), "exit 0\n")
    empty_env = { "PATH" => "", "HOME" => @tmp }

    assert_equal tool, ::Ocran::AotToolchain.find(:spinel, { "SPINEL" => tool }.merge(empty_env))
    assert_equal tool, ::Ocran::AotToolchain.find(:spinel, { "SPINEL" => @tmp }.merge(empty_env))
    assert_equal tool, ::Ocran::AotToolchain.find(:spinel, { "PATH" => @tmp, "HOME" => @tmp })

    err = assert_raises(RuntimeError) do
      ::Ocran::AotToolchain.find(:spinel, { "SPINEL" => File.join(@tmp, "nope") }.merge(empty_env))
    end
    assert_match(/SPINEL=.* does not name the spinel command/, err.message)
  end

  # The layout of Spinel's `make install`: the compiler and packages/ in
  # PREFIX/lib/spinel, a link to it and spinel-doctor in PREFIX/bin.
  def test_installed_layout
    posix_only
    require_relative "../lib/ocran/spinel_builder"
    prefix = File.join(@tmp, "prefix")
    FileUtils.mkdir_p([File.join(prefix, "bin"), File.join(prefix, "lib/spinel/packages")])
    compiler = write_script(File.join(prefix, "lib/spinel/spinel"), "exit 0\n")
    File.symlink(compiler, File.join(prefix, "bin/spinel"))
    doctor = write_script(File.join(prefix, "bin/spinel-doctor"), "exit 0\n")
    builder = ::Ocran::SpinelBuilder.allocate

    [compiler, File.join(prefix, "bin/spinel")].each do |spinel|
      assert_equal doctor, builder.send(:doctor_path, spinel)
      assert_equal File.join(File.realpath(prefix), "lib/spinel/packages"), builder.send(:packages_dir, spinel)
    end
  end

  def test_install_instructions
    text = ::Ocran::AotToolchain.install_instructions(%i[roundhouse spinel spin])
    assert_match(%r{git clone https://github.com/matz/spinel}, text)
    assert_match(/make install/, text)
    assert_match(/roundhouse-installer\.sh/, text)
    assert_match(/cargo install --git/, text)
    assert_match(/ROUNDHOUSE/, text)
  end

  def test_spinel_compiles_with_include_dirs
    posix_only
    dir = fixture("spinel")
    out, status = ocran(dir, "spinel.rb", "--spinel", "--spinel-opt", "--int-overflow=promote",
                        env: { "SPINEL" => fake_spinel })

    assert status.success?, out
    exe = File.join(dir, "spinel")
    assert File.executable?(exe), out
    args = File.read(File.join(@tmp, "spinel-args")).lines(chomp: true)
    assert_equal ["-I", File.join(dir, "lib")], args.first(2)
    assert_includes args, "--int-overflow=promote"
    assert_equal ["-o", exe], args.last(2)
  end

  # A script in a spin project is compiled with what `spin flags` prints:
  # its dependencies' roots and the objects of the C they carry. A library
  # a dependency provides is not reported, whatever gem has the same name.
  def fake_spin_project(fail: false, pkgs: "pkgs")
    project = File.join(@tmp, "proj")
    pkg = File.join(@tmp, pkgs, "curses")
    FileUtils.mkdir_p([File.join(project, "lib"), pkg, File.join(@tmp, "cache")])
    File.write(File.join(@tmp, "cache", "sp_curses.o"), "")
    File.write(File.join(project, "spin.toml"), "[package]\nname = \"proj\"\n")
    File.write(File.join(pkg, "curses.rb"), "module Curses; end\n")
    File.write(File.join(project, "app.rb"), %(require "curses"\nrequire "helper"\nputs Helper::X\n))
    File.write(File.join(project, "lib", "helper.rb"), "module Helper; X = 1; end\n")
    spin = write_script(File.join(@tmp, "bin", "spin"), <<~SH)
      pwd > "#{@tmp}/spin-cwd"
      [ "$1" = flags ] || exit 2
      #{fail ? 'echo "spin: curses has a native build step. Allow it with --allow-native-build" >&2; exit 1' : ""}
      echo "--strict-require -I #{pkg} -I #{project} --link #{@tmp}/cache/sp_curses.o --link -lcurses"
    SH
    [project, spin, pkg]
  end

  def test_spinel_in_spin_project
    posix_only
    spinel = fake_spinel
    project, spin, pkg = fake_spin_project
    out, status = ocran(project, "app.rb", "--spinel", env: { "SPINEL" => spinel, "SPIN" => spin })

    assert status.success?, out
    assert_equal File.realpath(project), File.realpath(File.read(File.join(@tmp, "spin-cwd")).strip)
    args = File.read(File.join(@tmp, "spinel-args")).lines(chomp: true)
    assert_equal ["--strict-require", "-I", pkg, "-I", project, "--link", "#{@tmp}/cache/sp_curses.o",
                  "--link", "-lcurses"], args.first(9)
    assert_equal ["-I", File.join(project, "lib")], args[9, 2]
    refute_match(/curses/, out.sub(/^.*spin project.*$/, ""))
  end

  def test_spin_root_search_stops_at_repository
    require_relative "../lib/ocran/spinel_builder"
    builder = ::Ocran::SpinelBuilder.allocate
    repo = File.join(@tmp, "outer", "repo")
    FileUtils.mkdir_p(File.join(repo, ".git"))
    FileUtils.mkdir_p(File.join(repo, "app", "bin"))
    File.write(File.join(@tmp, "outer", "spin.toml"), "")

    assert_nil builder.send(:find_spin_root, File.join(repo, "app", "bin"))
    File.write(File.join(repo, "app", "spin.toml"), "")
    assert_equal File.join(repo, "app"), builder.send(:find_spin_root, File.join(repo, "app", "bin"))
  end

  # spin prints its flags unquoted: a path with a space arrives in pieces,
  # which OCRAN refuses rather than guess how to rejoin.
  def test_spinel_spin_flags_path_with_space
    posix_only
    spinel = fake_spinel
    project, spin, = fake_spin_project(pkgs: "my pkgs")
    out, status = ocran(project, "app.rb", "--spinel", env: { "SPINEL" => spinel, "SPIN" => spin })

    refute status.success?, out
    assert_match(/names ".*my" \(-I\), which does not exist/, out)
    assert_match(/path without spaces/, out)
    refute File.exist?(File.join(@tmp, "spinel-args")), "spinel ran with a broken -I"
  end

  # A script in a subdirectory of a spin project requires files at the
  # project root, which spin passes as -I.
  def test_compatibility_resolves_from_search_roots
    root = File.join(@tmp, "proj")
    FileUtils.mkdir_p(File.join(root, "bin"))
    File.write(File.join(root, "app.rb"), "module App; end\n")
    File.write(File.join(root, "bin", "main.rb"), %(require "app"\n))
    analysis = ::Ocran::SpinelCompatibility.new(File.join(root, "bin", "main.rb"),
                                                 project_dirs: [root], search_roots: [root]).analyze

    assert_empty analysis.findings, analysis.report
    assert_includes analysis.project_files.map(&:to_s), File.join(root, "app.rb")
  end

  def test_toolchain_locations_on_windows
    exe = File.join(@tmp, "spinel", "bin", "spinel.exe")
    FileUtils.mkdir_p(File.dirname(exe))
    File.write(exe, "")
    pattern = File.join(@tmp, "spinel", "bin", "spinel")

    assert_equal [exe], ::Ocran::AotToolchain.location_candidates(pattern, windows: true)
    assert_empty ::Ocran::AotToolchain.location_candidates(pattern, windows: false)
  end

  def test_spinel_spin_flags_failure
    posix_only
    spinel = fake_spinel
    project, spin, = fake_spin_project(fail: true)
    out, status = ocran(project, "app.rb", "--spinel", env: { "SPINEL" => spinel, "SPIN" => spin })

    refute status.success?, out
    assert_match(/spin could not resolve the project's dependencies/, out)
    assert_match(/SPIN_ALLOW_NATIVE_BUILD=1/, out)
    refute File.exist?(File.join(@tmp, "spinel-args")), "spinel ran although spin flags failed"
  end

  def test_spinel_failure_reports_incompatibilities
    posix_only
    dir = fixture("spinel_incompatible")
    out, status = ocran(dir, "spinel_incompatible.rb", "--spinel",
                        env: { "SPINEL" => fake_spinel, "FAKE_SPINEL_FAIL" => "1" })

    refute status.success?, out
    assert_match(/spinel: cannot compile: eval is not supported/, out)
    assert_match(/What may stand in the way/, out)
    assert_match(/eval of a string is not supported/, out)
    assert_match(/ERROR: Spinel could not compile/, out)
  end

  def test_spinel_missing_explains_installation
    posix_only
    dir = fixture("spinel_incompatible")
    # A home and PATH without Spinel; the conventional system-wide
    # locations cannot be hidden, so skip where one has it.
    env = { "PATH" => "/usr/bin:/bin", "HOME" => @tmp, "SPINEL" => nil }
    skip "Spinel is installed system-wide" if ::Ocran::AotToolchain.find(:spinel, env.compact)

    out, status = ocran(dir, "spinel_incompatible.rb", "--spinel", env: env)
    refute status.success?, out
    assert_match(/--spinel needs the Spinel compiler, which was not found/, out)
    assert_match(%r{git clone https://github.com/matz/spinel}, out)
    assert_match(/static check of whether spinel_incompatible\.rb is likely to compile/, out)
    assert_match(/eval of a string is not supported/, out)
  end

  def test_spinel_rejects_packaging_options
    dir = fixture("spinel")
    out, status = ocran(dir, "spinel.rb", "--spinel", "--output-zip", "x.zip")
    refute status.success?
    assert_match(/--output-zip cannot be used with --spinel/, out)
  end

  # The real compiler, when there is one.
  def test_spinel_end_to_end
    spinel = ::Ocran::AotToolchain.find(:spinel)
    skip "Spinel not found (set SPINEL or put spinel in PATH)" unless spinel

    dir = fixture("spinel")
    out, status = ocran(dir, "spinel.rb", "--spinel")
    assert status.success?, out

    exe = File.join(dir, Gem.win_platform? ? "spinel.exe" : "spinel")
    run_out, run_status = Open3.capture2e(exe)
    assert run_status.success?, run_out
    assert_equal "Hello, spinel!\nCOMPILED!\n", run_out
  end

  # Stand-ins for roundhouse and spin. `roundhouse check` prints a gem
  # census; the transpile fails when FAKE_TRANSPILE_FAIL is set.
  def fake_roundhouse_tools
    bin = File.join(@tmp, "bin")
    FileUtils.mkdir_p(bin)
    write_script(File.join(bin, "roundhouse"), <<~SH)
      [ "$1" = "--version" ] && { echo "roundhouse 0.0 (stand-in)"; exit 0; }
      if [ "$1" = "check" ]; then
        echo "app/models/post.rb:3:5: error[send_dispatch_failed]: no known method frobnicate on Post"
        echo "roundhouse-check: 12 gems: 9 framework, 0 modeled, 2 infrastructure, 1 unknown (frobnicator)"
        echo "roundhouse-check: app - 0 parse error(s), 1 error(s), 0 warning(s), 0 gap-attributed note(s), 0 survey gap(s)"
        exit 1
      fi
      if [ -n "$FAKE_TRANSPILE_FAIL" ]; then
        echo "roundhouse: unsupported construct in app/models/post.rb" >&2
        exit 1
      fi
      while [ $# -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift; fi
        shift
      done
      [ -n "$out" ] || { echo "roundhouse: no -o" >&2; exit 2; }
      mkdir -p "$out/db" "$out/config"
      printf 'assets:\\n\\tbundle exec ruby -e 1\\n' > "$out/Makefile"
      printf '[package]\\nallocator = "jemalloc"\\n' > "$out/spin.toml"
      echo "CREATE TABLE posts (id INTEGER PRIMARY KEY);" > "$out/db/seed.sql"
    SH
    # Like the generated Makefile, `make assets` writes static/.
    write_script(File.join(bin, "make"), <<~SH)
      [ "$1" = "assets" ] || exit 2
      [ -n "$FAKE_ASSETS_FAIL" ] && { echo "npx: command not found" >&2; exit 1; }
      echo "make $* BUNDLE_ONLY=$BUNDLE_ONLY" >> "#{@tmp}/asset-log"
      mkdir -p static/assets
      echo "body {}" > static/assets/app.css
    SH
    write_script(File.join(bin, "bundle"), <<~SH)
      echo "bundle $* BUNDLE_ONLY=$BUNDLE_ONLY" >> "#{@tmp}/asset-log"
    SH
    write_script(File.join(bin, "pkg-config"), <<~SH)
      [ "$1 $2" = "--libs-only-L jemalloc" ] && echo "-L/opt/fake/jemalloc/lib"
    SH
    write_script(File.join(bin, "spin"), <<~SH)
      [ "$1" = "build" ] || exit 2
      command -v spinel > /dev/null || { echo "spinel not on PATH" >&2; exit 3; }
      echo "$LIBRARY_PATH" > "#{@tmp}/spin-library-path"
      if [ -n "$FAKE_LINK_FAIL" ]; then
        echo "ld: library 'jemalloc' not found" >&2
        exit 1
      fi
      mkdir -p build/bin
      printf '#!/bin/sh\\necho serving\\n' > build/bin/blog
      chmod +x build/bin/blog
    SH
    write_script(File.join(bin, "spinel"), "exit 0\n")
    bin
  end

  def rails_app
    app = File.join(@tmp, "blog")
    FileUtils.mkdir_p([File.join(app, "config"), File.join(app, "app")])
    File.write(File.join(app, "config", "application.rb"), "")
    app
  end

  def test_roundhouse_builds_directory
    posix_only
    bin = fake_roundhouse_tools
    rails_app
    env = { "ROUNDHOUSE" => File.join(bin, "roundhouse"), "SPIN" => File.join(bin, "spin"),
            "SPINEL" => File.join(bin, "spinel") }
    out, status = ocran(@tmp, "--roundhouse", "blog", env: env)

    assert status.success?, out
    target = File.join(@tmp, "blog-spinel")
    assert File.executable?(File.join(target, "blog")), out
    assert File.file?(File.join(target, "static", "assets", "app.css")), out
    assert File.file?(File.join(target, "db", "seed.sql")), out
    assert File.directory?(File.join(target, "storage")), out
    assert_match(/Run it with: cd blog-spinel && \.\/blog/, out)
    # The assets came from `make assets`, with only the assets group bundled.
    assert_equal ["bundle install BUNDLE_ONLY=assets", "make assets BUNDLE_ONLY=assets"],
                 File.readlines(File.join(@tmp, "asset-log"), chomp: true)
    # spin build saw pkg-config's directory for the allocator spin.toml names.
    assert_match(%r{\A/opt/fake/jemalloc/lib}, File.read(File.join(@tmp, "spin-library-path")))
  end

  def test_roundhouse_asset_failure_stops_the_build
    posix_only
    bin = fake_roundhouse_tools
    rails_app
    env = { "ROUNDHOUSE" => File.join(bin, "roundhouse"), "SPIN" => File.join(bin, "spin"),
            "SPINEL" => File.join(bin, "spinel"), "FAKE_ASSETS_FAIL" => "1" }
    out, status = ocran(@tmp, "--roundhouse", "blog", env: env)

    refute status.success?, out
    assert_match(/Building the static assets failed \(make assets\)/, out)
    assert_match(/npx: command not found/, out)
    assert_match(/BUNDLE_ONLY=assets make assets/, out)
    refute File.exist?(File.join(@tmp, "spin-library-path")), "spin build must not run without assets"
  end

  def test_roundhouse_link_failure_names_the_library
    posix_only
    bin = fake_roundhouse_tools
    rails_app
    env = { "ROUNDHOUSE" => File.join(bin, "roundhouse"), "SPIN" => File.join(bin, "spin"),
            "SPINEL" => File.join(bin, "spinel"), "FAKE_LINK_FAIL" => "1" }
    out, status = ocran(@tmp, "--roundhouse", "blog", env: env)

    refute status.success?, out
    assert_match(/the linker could not find libjemalloc/, out)
    assert_match(/set LIBRARY_PATH/, out)
  end

  def test_roundhouse_failure_shows_gem_census
    posix_only
    bin = fake_roundhouse_tools
    app = rails_app
    env = { "ROUNDHOUSE" => File.join(bin, "roundhouse"), "SPIN" => File.join(bin, "spin"),
            "SPINEL" => File.join(bin, "spinel"), "FAKE_TRANSPILE_FAIL" => "1" }
    # The application directory is found from a file inside it, too.
    out, status = ocran(app, "--roundhouse", "config/application.rb", env: env)

    refute status.success?, out
    assert_match(/Roundhouse could not transpile/, out)
    assert_match(/unsupported construct in app\/models\/post\.rb/, out)
    assert_match(/1 unknown \(frobnicator\)/, out)
    assert_match(/gems are ones Roundhouse does not model/, out)
    assert_match(/error\[send_dispatch_failed\]/, out)
  end

  def test_roundhouse_missing_tools_explains_installation
    posix_only
    bin = fake_roundhouse_tools
    rails_app
    # roundhouse is there, Spinel is not: install help plus the analysis.
    env = { "ROUNDHOUSE" => File.join(bin, "roundhouse"), "PATH" => "/usr/bin:/bin", "HOME" => @tmp,
            "SPIN" => nil, "SPINEL" => nil }
    lookup_env = env.compact
    skip "Spinel is installed system-wide" if ::Ocran::AotToolchain.find(:spinel, lookup_env) ||
                                               ::Ocran::AotToolchain.find(:spin, lookup_env)

    out, status = ocran(@tmp, "--roundhouse", "blog", env: env)
    refute status.success?, out
    assert_match(/--roundhouse needs `spinel` and `spin`, which were not found/, out)
    assert_match(/make install/, out)
    assert_match(/1 unknown \(frobnicator\)/, out)
  end

  def test_roundhouse_requires_rails_app
    out, status = ocran(@tmp, "--roundhouse", ".")
    refute status.success?
    assert_match(/is not a Rails application/, out)
  end
end
