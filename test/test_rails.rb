# frozen_string_literal: true

# End-to-end packaging test for a real Rails application backed by SQLite.
#
# This is deliberately kept out of test/test_ocra.rb: it needs Rails on the
# build host, it generates a whole application from scratch, and it runs an
# HTTP server - none of which the rest of the suite should have to care
# about. It is opt-in (see OPT_IN_ENV below), so a plain `rake test` never
# reaches any of it.
#
# What it proves, in one run:
#   * `rails new` + `bin/rails generate scaffold` output can be packaged;
#   * so can controllers, routes and ERB views written after scaffolding,
#     which never went through a generator;
#   * the packaged binary really serves HTTP - a scaffold CRUD round-trip
#     goes through ActiveRecord into a real SQLite file;
#   * that SQLite file lands next to the executable and survives a restart,
#     which is the runtime-writable-path question from github issue #32.

require "minitest/autorun"

require "fileutils"
require "json"
require "net/http"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require "uri"

require_relative "rails_app_generator"

class TestRails < Minitest::Test
  # Packaging Rails needs the rails gem, ~1 GB of temporary disk and the
  # better part of a minute, so it never runs by accident.
  OPT_IN_ENV = "OCRAN_RAILS_TEST"

  OcranRoot = File.expand_path("..", __dir__)
  TESTED_OCRAN = ENV["TESTED_OCRAN"] || "ocran"

  # --no-autoload matters: OCRAN's autoload walker sweeps every Module in
  # ObjectSpace, and under Rails that means trying to const_get the whole
  # of I18n::Tests, Prism::Translation and friends - minutes of noise ending
  # in a load error. Rails eager-loads the application itself in production,
  # so there is nothing for the walker to find anyway.
  #
  # --gem-all matters too: Rails reads a lot of .rb and .yml it never
  # `require`s (activesupport/locale/en.rb is the first one to bite), and
  # OCRAN's dependency detection only sees $LOADED_FEATURES.
  BUILD_ARGS = %w[--no-lzma --no-autoload --gem-all --verbose].tap do |args|
    args << "--quiet" unless ENV["OCRAN_VERBOSE_TEST"]
  end.freeze

  # Booting Rails out of a freshly unpacked ~50 MB payload is not instant,
  # and CI disks are slower than this one.
  BOOT_TIMEOUT = Integer(ENV["OCRAN_RAILS_BOOT_TIMEOUT"] || 180)

  def ocran = File.join(OcranRoot, "exe", TESTED_OCRAN)

  def exe_name(base) = Gem.win_platform? ? "#{base}.exe" : base

  # --- gating ----------------------------------------------------------

  def require_prereqs
    unless ENV[OPT_IN_ENV].to_s == "1"
      skip "set #{OPT_IN_ENV}=1 to run the Rails packaging test (it needs the rails gem and generates an app)"
    end

    unless rails_available?
      skip "the rails gem is not installed on this host (gem install rails)"
    end

    %w[sqlite3 puma].each do |name|
      Gem::Specification.find_by_name(name)
    rescue Gem::LoadError
      skip "the #{name} gem is not installed on this host"
    end

    stub = File.join(OcranRoot, "share", "ocran", exe_name("stub"))
    unless File.exist?(stub)
      skip "#{stub} is missing (run `make -C src install`)"
    end
  end

  def rails_available?
    out, status = Open3.capture2e("rails", "--version")
    status&.success? && out.include?("Rails")
  rescue SystemCallError
    false
  end

  # --- the tests -------------------------------------------------------

  # The must-have: the ordinary OCRAN stub around the host Ruby.
  def test_rails_sqlite_server_native
    require_prereqs

    with_workspace do |work|
      app = generate_app(work)
      exe = build(app, work, File.join(work, "dist", exe_name("rails_demo")))

      # Run from a directory that is not the build directory, in an
      # environment that carries nothing over from this process, so what is
      # exercised is the package and not the source tree it came from.
      run_dir = File.join(work, "run")
      FileUtils.mkdir_p(run_dir)
      exe_copy = File.join(run_dir, File.basename(exe))
      FileUtils.cp(exe, exe_copy)
      FileUtils.chmod(0755, exe_copy)

      db = File.join(run_dir, "railsdemo-data", "demo.sqlite3")

      with_server(exe_copy, run_dir) do |http|
        status = assert_status_endpoint(http, packaged: true, expected_db: db)
        assert_equal "SQLite", status["adapter"]
        refute_empty status["sqlite_version"].to_s

        assert_scaffold_crud_round_trip(http)
        assert_dynamic_controllers(http)

        # Leave one record behind for the restart check.
        create_widget(http, "Persisted", 42)
      end

      assert File.file?(db), "expected the SQLite database next to the executable at #{db}"
      refute File.exist?(File.join(run_dir, "storage")),
             "the app must not fall back to Rails.root/storage for its database"

      # Second run of the same executable: the stub unpacks into a brand new
      # temporary directory, so anything that survived did so because it was
      # written next to the binary rather than inside the package.
      with_server(exe_copy, run_dir) do |http|
        status = assert_status_endpoint(http, packaged: true, expected_db: db)
        assert_equal 1, status["widget_count"],
                     "the record created by the previous run should still be in the database"

        body = get_body(http, "/report")
        assert_match(/TOTAL=42/, body)
        assert_match(/class="row">Persisted=42/, body)
      end
    end
  end

  # "Would be cool if it works": the same application behind a cosmopolitan
  # Ruby APE. Rails drags in native-extension gems, and an APE cannot
  # dlopen anything, so whether this can work at all depends entirely on
  # what the given interpreter has compiled in.
  #
  # The test therefore asserts the outcome that is actually true of the
  # interpreter it is handed: either the build is refused with a diagnostic
  # that names the offending native gem (today's case - see the Rails
  # section of README.md), or it succeeds and then has to serve HTTP just
  # like the native build.
  def test_rails_sqlite_server_cosmo_ruby
    require_prereqs
    skip "--cosmo-ruby requires a POSIX build host" if Gem.win_platform?
    cosmo_ruby = ENV["COSMO_RUBY"].to_s
    skip "cosmopolitan Ruby not found (set COSMO_RUBY to a ruby.com APE)" unless File.file?(cosmo_ruby)

    with_workspace do |work|
      app = generate_app(work)
      out = File.join(work, "dist", "rails_demo.com")
      FileUtils.mkdir_p(File.dirname(out))

      log, status = run_ocran(app, work, out, extra: ["--cosmo-ruby", cosmo_ruby])

      unless status.success?
        # Blocked, which is the expected result for every cosmopolitan Ruby
        # published so far. Insist that the failure is the documented one:
        # a native gem the payload does not provide, named explicitly.
        assert_match(/is native .* and cannot run under the packed cosmopolitan Ruby/, log,
                     "expected OCRAN to refuse the build with a native-gem diagnostic, got:\n#{tail(log)}")
        offender = log[/Gem (\S+) is native/, 1]
        refute_nil offender, "the diagnostic should name the gem:\n#{tail(log)}"
        skip "Rails cannot be packaged with this cosmopolitan Ruby: #{offender} " \
             "is a native-extension gem the interpreter does not provide " \
             "(see the Rails section of README.md)"
      end

      # The interpreter has everything Rails needs compiled in. Then it has
      # to actually work.
      assert File.exist?(out), "ocran reported success but produced no #{out}"
      run_dir = File.join(work, "run")
      FileUtils.mkdir_p(run_dir)
      exe_copy = File.join(run_dir, "rails_demo.com")
      FileUtils.cp(out, exe_copy)
      FileUtils.chmod(0755, exe_copy)

      db = File.join(run_dir, "railsdemo-data", "demo.sqlite3")
      with_server(exe_copy, run_dir) do |http|
        assert_status_endpoint(http, packaged: true, expected_db: db)
        assert_scaffold_crud_round_trip(http)
        assert_dynamic_controllers(http)
      end
    end
  end

  # --- build -----------------------------------------------------------

  def with_workspace
    dir = Dir.mktmpdir(".ocran-rails-")
    yield dir
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def generate_app(work)
    t0 = Time.now
    app = RailsAppGenerator.generate(File.join(work, "app"))
    note "generated the Rails application in %.1fs" % (Time.now - t0)
    app
  end

  def build(app, work, out)
    FileUtils.mkdir_p(File.dirname(out))
    t0 = Time.now
    log, status = run_ocran(app, work, out)
    assert status&.success?,
           "ocran failed (exit #{status&.exitstatus.inspect}):\n#{tail(log)}"
    assert File.exist?(out), "ocran reported success but produced no #{out}:\n#{tail(log)}"
    note "packaged %.1f MB in %.1fs" % [File.size(out) / 1024.0 / 1024.0, Time.now - t0]
    out
  end

  def run_ocran(app, work, out, extra: [])
    # The dependency run loads server.rb, which creates and migrates a
    # database; keep that scratch copy out of the application directory.
    env = { "RAILS_DEMO_DATA" => File.join(work, "builddata"), "RUBYOPT" => "" }
    cmd = [env, RbConfig.ruby, ocran, "server.rb", "app", "config", "db", "public",
           *BUILD_ARGS, *extra, "--output", out]
    puts cmd[1..].join(" ") if ENV["OCRAN_VERBOSE_TEST"]
    log, status = Open3.capture2e(*cmd, chdir: app)
    print log if ENV["OCRAN_VERBOSE_TEST"]
    [log, status]
  end

  # --- running the packaged server -------------------------------------

  # Starts the packaged executable, waits for it to serve, yields an HTTP
  # client, and always tears the process down - a Rails server that failed
  # to come up must not wedge the suite.
  def with_server(exe, dir)
    port = free_port
    log_path = File.join(dir, "server-#{port}.log")
    log = File.open(log_path, "w")
    pid = Process.spawn(server_env(port), exe,
                        chdir: dir, out: log, err: [:child, :out],
                        **spawn_isolation)
    log.close

    wait_until_ready(pid, port, log_path)
    yield HttpClient.new(port)
  ensure
    stop(pid) if pid
    if ENV["OCRAN_VERBOSE_TEST"] && log_path && File.exist?(log_path)
      puts File.read(log_path)
    end
  end

  # A minimal environment: no RUBYOPT, no GEM_PATH, nothing this test
  # process is carrying. The packaged executable has to supply all of it.
  def server_env(port)
    env = { "PORT" => port.to_s }
    if Gem.win_platform?
      root = ENV["SystemRoot"].to_s
      env["SystemRoot"] = root
      env["PATH"] = "#{root};#{root}\\SYSTEM32"
      %w[TEMP TMP USERPROFILE].each { |k| env[k] = ENV[k] if ENV[k] }
    else
      env["PATH"] = "/usr/local/bin:/usr/bin:/bin"
      env["HOME"] = ENV["HOME"] if ENV["HOME"]
    end
    env
  end

  def spawn_isolation
    opts = { unsetenv_others: true }
    # Own process group, so a stuck server and anything it forked can be
    # killed together instead of one pid at a time.
    opts[:pgroup] = true unless Gem.win_platform?
    opts
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_until_ready(pid, port, log_path)
    deadline = Time.now + BOOT_TIMEOUT
    loop do
      if Process.waitpid(pid, Process::WNOHANG)
        flunk "the packaged server exited before it started serving:\n#{tail(File.read(log_path))}"
      end

      begin
        Net::HTTP.start("127.0.0.1", port, open_timeout: 2, read_timeout: 5) do |http|
          return if http.request(Net::HTTP::Get.new("/status")).code == "200"
        end
      rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, EOFError, IOError
        # not up yet
      end

      if Time.now > deadline
        flunk "the packaged server did not answer on 127.0.0.1:#{port} within #{BOOT_TIMEOUT}s:\n" \
              "#{tail(File.read(log_path))}"
      end
      sleep 0.25
    end
  end

  def stop(pid)
    target = Gem.win_platform? ? pid : -Process.getpgid(pid)
    signal(target, Gem.win_platform? ? "KILL" : "TERM")
    return if reaped?(pid, 20)

    signal(target, "KILL")
    reaped?(pid, 10)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def signal(target, name)
    Process.kill(name, target)
  rescue Errno::ESRCH, Errno::EPERM, Errno::ECHILD
    nil
  end

  def reaped?(pid, timeout)
    deadline = Time.now + timeout
    until Time.now > deadline
      return true if Process.waitpid(pid, Process::WNOHANG)

      sleep 0.1
    end
    false
  rescue Errno::ECHILD
    true
  end

  # --- HTTP assertions -------------------------------------------------

  # The dynamically added JSON controller, which reports what the packaged
  # process can see about itself.
  def assert_status_endpoint(http, packaged:, expected_db:)
    res = http.get("/status")
    assert_equal "200", res.code, "GET /status: #{res.body}"
    body = JSON.parse(res.body)

    assert_equal true, body["ok"]
    assert_equal "production", body["env"]
    assert_equal packaged, body["packaged"],
                 "OCRAN_EXECUTABLE should be #{packaged ? "set" : "unset"} (got #{body["executable"].inspect})"
    assert_equal expected_db, body["database"],
                 "the SQLite database must live next to the executable, not inside the package"
    assert_match(/\A\d+\.\d+/, body["rails"].to_s)
    body
  end

  # A full CRUD round trip through the generated scaffold, driven the way a
  # browser would: HTML forms, the CSRF token out of the page, the session
  # cookie carried along. Every step goes through ActiveRecord to SQLite.
  def assert_scaffold_crud_round_trip(http)
    res = http.get("/widgets/new")
    assert_equal "200", res.code
    assert_match(/name="authenticity_token"/, res.body, "the scaffold form should be rendered from the packaged ERB")

    location = create_widget(http, "Sprocket", 7)
    path = URI(location).path

    res = http.get(path)
    assert_equal "200", res.code
    assert_match(/Sprocket/, res.body)

    res = http.get("/widgets")
    assert_equal "200", res.code
    assert_match(/Sprocket/, res.body, "the new record should show up in the scaffold index")

    # Update
    res = http.get("#{path}/edit")
    assert_equal "200", res.code
    res = http.patch(path, "authenticity_token" => http.csrf_token(res.body), "widget[qty]" => "11")
    assert_includes %w[302 303], res.code, "PATCH #{path}: #{res.body[0, 300]}"
    assert_match(/TOTAL=11/, get_body(http, "/report"), "the update should be visible through the database")

    # Destroy
    res = http.get(path)
    res = http.delete(path, "authenticity_token" => http.csrf_token(res.body))
    assert_includes %w[302 303], res.code, "DELETE #{path}: #{res.body[0, 300]}"
    refute_match(/Sprocket/, get_body(http, "/widgets"), "the record should be gone from the index")
  end

  # The controllers, route and ERB template that were written after
  # scaffolding rather than generated.
  def assert_dynamic_controllers(http)
    body = get_body(http, "/report")
    assert_match(/<h1>Widget report<\/h1>/, body, "the dynamically added ERB view should render")
    assert_match(/id="total">TOTAL=\d+/, body)

    location = create_widget(http, "Dynamic", 5)
    body = get_body(http, "/report")
    assert_match(/TOTAL=5/, body)
    assert_match(/class="row">Dynamic=5/, body)

    res = http.get(location)
    res = http.delete(URI(location).path, "authenticity_token" => http.csrf_token(res.body))
    assert_includes %w[302 303], res.code
  end

  def create_widget(http, name, qty)
    res = http.get("/widgets/new")
    token = http.csrf_token(res.body)
    refute_nil token, "no CSRF token in the scaffold form"

    res = http.post("/widgets", "authenticity_token" => token,
                                "widget[name]" => name, "widget[qty]" => qty.to_s)
    assert_includes %w[302 303], res.code, "POST /widgets: #{res.body[0, 500]}"
    res["location"]
  end

  def get_body(http, path)
    res = http.get(path)
    assert_equal "200", res.code, "GET #{path}: #{res.body[0, 300]}"
    res.body
  end

  # --- misc ------------------------------------------------------------

  def note(message)
    puts "  [rails] #{message}" if ENV["OCRAN_VERBOSE_TEST"] || ENV["OCRAN_RAILS_NOTES"]
  end

  def tail(text, lines = 40)
    out = text.to_s.lines.last(lines).join
    out.strip.empty? ? "(no output)" : out
  end

  # Just enough of a browser: keeps the session cookie and can find the
  # CSRF token Rails puts in its forms.
  class HttpClient
    def initialize(port, host: "127.0.0.1")
      @host = host
      @port = port
      @cookie = nil
    end

    def get(path) = request(Net::HTTP::Get.new(path_of(path)))
    def post(path, form) = request(form_request(Net::HTTP::Post, path, form))
    def patch(path, form) = request(form_request(Net::HTTP::Patch, path, form))
    def delete(path, form) = request(form_request(Net::HTTP::Delete, path, form))

    def csrf_token(body)
      body[/name="authenticity_token"[^>]*\svalue="([^"]+)"/, 1] ||
        body[/name="csrf-token"\s+content="([^"]+)"/, 1]
    end

    private

    def path_of(path) = path.start_with?("http") ? URI(path).request_uri : path

    def form_request(klass, path, form)
      klass.new(path_of(path)).tap { |req| req.form_data = form }
    end

    def request(req)
      req["Cookie"] = @cookie if @cookie
      res = Net::HTTP.start(@host, @port, open_timeout: 5, read_timeout: 30) { |h| h.request(req) }
      if (set = res.get_fields("set-cookie"))
        @cookie = set.map { |c| c.split(";", 2).first }.join("; ")
      end
      res
    end
  end
end
