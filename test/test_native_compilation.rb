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
    assert_match(/dynamic\.rb:6: define_method with a computed name works only where/, report)
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
      mkdir -p "$out/static/assets" "$out/db" "$out/config"
      echo "body {}" > "$out/static/assets/app.css"
      echo "CREATE TABLE posts (id INTEGER PRIMARY KEY);" > "$out/db/seed.sql"
    SH
    write_script(File.join(bin, "spin"), <<~SH)
      [ "$1" = "build" ] || exit 2
      command -v spinel > /dev/null || { echo "spinel not on PATH" >&2; exit 3; }
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
