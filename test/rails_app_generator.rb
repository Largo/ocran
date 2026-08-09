# frozen_string_literal: true

require "fileutils"
require "open3"

# Generates the Rails application that test/test_rails.rb packages.
#
# Nothing about the application is committed to this repository: it is
# produced from scratch by `rails new` and `bin/rails generate scaffold`
# every time the test runs, then extended with controllers, routes and
# views written programmatically. That way the test covers both what the
# Rails generators emit and code added on the fly, and OCRAN is never
# handed a hand-curated fixture that happens to package well.
module RailsAppGenerator
  module_function

  # Flags worth passing to `rails new` for a small, dependency-light app.
  # They are filtered against `rails new --help` so that a Rails version
  # without one of them (they were added across 7.x and 8.x) does not turn
  # the whole test into an error.
  CANDIDATE_FLAGS = %w[
    --minimal --skip-git --skip-test --skip-bundle --skip-asset-pipeline
    --skip-bootsnap --skip-docker --skip-ci --skip-kamal --skip-solid
    --skip-dev-gems
  ].freeze

  # Gems whose gemspecs Rails carries but whose code a running server never
  # loads. RubyGems activates the *declared* dependency graph of every
  # gemspec inside the package, so these have to be in the executable even
  # though nothing requires them; see the "Rails" section of README.md.
  UNLOADED_RUNTIME_DEPS = <<~RUBY
    # Rails declares these but a running server never loads them, so OCRAN
    # would not pack them. RubyGems still activates the full dependency
    # graph of every packed gemspec and would then fail with
    # Gem::MissingSpecError. Requiring them here is what puts them in.
    begin
      gem "minitest", "~> 5.0"  # 5.x has no dependencies of its own
    rescue Gem::LoadError
      # fall back to whatever minitest the host has
    end
    require "minitest"  # activesupport
    require "drb"       # activesupport
    require "rake"      # railties
  RUBY

  # Builds the application in +dir+ (which must not exist yet) and returns
  # the path of the application root.
  def generate(dir, name: "demo")
    FileUtils.mkdir_p(dir)
    app = File.join(dir, name)

    run!(["rails", "new", name, *supported_flags, "--database=sqlite3", "--quiet"], chdir: dir)
    detach_from_bundler(app)
    run!(["bin/rails", "generate", "scaffold", "Widget", "name:string", "qty:integer", "--quiet"],
         chdir: app)
    add_dynamic_code(app)
    configure_for_packaging(app)
    write_entry_point(app)

    app
  end

  # `rails new` flags this Rails version actually understands.
  def supported_flags
    help, = Open3.capture2e("rails", "new", "--help")
    CANDIDATE_FLAGS.select { |flag| help.include?(flag) }
  rescue SystemCallError
    CANDIDATE_FLAGS
  end

  # The generated app boots through `bundler/setup`, which needs the
  # Gemfile.lock that --skip-bundle did not produce, and which would also
  # confine OCRAN's dependency run to the bundle. Plain RubyGems activation
  # is enough for a test app, and it keeps the test off the network.
  def detach_from_bundler(app)
    write(app, "config/boot.rb", <<~RUBY)
      # Bundler-free boot: gems are activated by RubyGems. `rails new`
      # normally requires "bundler/setup" here.
    RUBY

    edit(app, "config/application.rb") do |src|
      src.sub("Bundler.require(*Rails.groups)", <<~RUBY.strip)
        # Bundler.require(*Rails.groups) replaced: no bundle here.
        require "sqlite3"
        require "puma"
      RUBY
    end
  end

  # Controllers, routes and a view written after scaffolding. These files
  # never went through a Rails generator, so packaging them exercises the
  # "code added on the fly" half of the test.
  def add_dynamic_code(app)
    write(app, "app/controllers/status_controller.rb", <<~RUBY)
      # Added programmatically by the test, not by a Rails generator.
      # Reports what the packaged process can see about itself, so the
      # assertions can prove they are talking to the packaged binary and
      # to a real SQLite database.
      class StatusController < ApplicationController
        def show
          render json: {
            ok: true,
            rails: Rails.version,
            env: Rails.env.to_s,
            ruby: RUBY_VERSION,
            platform: RUBY_PLATFORM,
            packaged: !ENV["OCRAN_EXECUTABLE"].nil?,
            executable: ENV["OCRAN_EXECUTABLE"].to_s,
            script: $0.to_s,
            database: ActiveRecord::Base.connection_db_config.database.to_s,
            adapter: ActiveRecord::Base.connection.adapter_name,
            sqlite_version: ActiveRecord::Base.connection.select_value("select sqlite_version()").to_s,
            widget_count: Widget.count
          }
        end
      end
    RUBY

    write(app, "app/controllers/report_controller.rb", <<~RUBY)
      # Second dynamic controller: renders an ERB template that was also
      # added on the fly, so template lookup and compilation are covered
      # for non-generated views too.
      class ReportController < ApplicationController
        def index
          @widgets = Widget.order(:id).to_a
          @total = @widgets.sum { |w| w.qty.to_i }
        end
      end
    RUBY

    write(app, "app/views/report/index.html.erb", <<~ERB)
      <h1>Widget report</h1>
      <p id="total">TOTAL=<%= @total %></p>
      <ul>
      <% @widgets.each do |widget| %>
        <li class="row"><%= widget.name %>=<%= widget.qty %></li>
      <% end %>
      </ul>
    ERB

    edit(app, "config/routes.rb") do |src|
      src.sub("Rails.application.routes.draw do", <<~RUBY.rstrip)
        Rails.application.routes.draw do
          # Routes added on the fly by the test.
          get "status" => "status#show"
          get "report" => "report#index"
          root "widgets#index"
      RUBY
    end
  end

  def configure_for_packaging(app)
    edit(app, "config/environments/production.rb") do |src|
      # The generated production config assumes an SSL-terminating proxy in
      # front of the app; the test talks plain HTTP to 127.0.0.1.
      src = src.sub("config.assume_ssl = true", "config.assume_ssl = false")
      src = src.sub("config.force_ssl = true", "config.force_ssl = false")
      # The default file cache store writes under Rails.root/tmp, which is
      # not a place a packaged app may write.
      src.sub("Rails.application.configure do",
              "Rails.application.configure do\n  config.cache_store = :memory_store")
    end

    # Rails 8 blocks non-"modern" browsers, and a Net::HTTP client is not
    # one. That gate is Rails' business, not OCRAN's.
    edit(app, "app/controllers/application_controller.rb") do |src|
      src.sub(/^\s*allow_browser.*$/, "  # allow_browser disabled: the test client is not a browser")
    end

    edit(app, "config/application.rb") do |src|
      # Rails::Application.find_root walks up from config/application.rb
      # looking for config.ru. Pin the root instead, so it is unambiguous
      # wherever OCRAN unpacks the application.
      src.sub("config.load_defaults", <<~RUBY.strip)
        config.root = File.expand_path("..", __dir__)
            # Rails writes to tmp (cache, pids, sockets); redirect it to a
            # writable directory chosen by server.rb.
            config.paths["tmp"] = ENV["RAILS_DEMO_TMP"] if ENV["RAILS_DEMO_TMP"]
            config.load_defaults
      RUBY
    end
  end

  # The script OCRAN is pointed at.
  def write_entry_point(app)
    write(app, "server.rb", <<~RUBY)
      # OCRAN entry point for the packaged Rails server.
      require "fileutils"

      # Where mutable state goes.
      #
      # The packaged application directory is NOT a place to write: with the
      # native stub it is a temporary directory that is deleted when the
      # process exits, and with --cosmo-ruby it is a read-only ZIP store
      # inside the executable itself. ENV["OCRAN_EXECUTABLE"] is the full
      # path of the running executable (github issue #32), so the database,
      # Rails' tmp directory and anything else that has to survive live next
      # to the binary instead.
      base =
        if (exe = ENV["OCRAN_EXECUTABLE"])
          File.dirname(File.expand_path(exe))
        else
          __dir__
        end
      data_dir = ENV["RAILS_DEMO_DATA"] || File.join(base, "railsdemo-data")
      FileUtils.mkdir_p(data_dir)

      ENV["RAILS_ENV"]       ||= "production"
      ENV["SECRET_KEY_BASE"] ||= "0" * 64
      ENV["DATABASE_URL"]    ||= "sqlite3:\#{File.join(data_dir, "demo.sqlite3")}"
      ENV["RAILS_DEMO_TMP"]  ||= File.join(data_dir, "tmp")
      FileUtils.mkdir_p(ENV["RAILS_DEMO_TMP"])

      #{UNLOADED_RUNTIME_DEPS}
      require_relative "config/environment"

      # Bring the schema up to date from the packed migrations. Running this
      # during OCRAN's dependency run too is deliberate: it is what puts
      # db/migrate/*.rb into $LOADED_FEATURES, which is how they get packed.
      ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate").to_s).migrate

      if defined?(Ocran)
        # OCRAN's dependency run: everything is loaded, do not start serving.
        warn "[server.rb] dependency run complete"
      else
        require "puma"
        port = Integer(ENV["PORT"] || 3000)
        server = Puma::Server.new(Rails.application)
        server.add_tcp_listener("127.0.0.1", port)
        %w[INT TERM].each do |sig|
          next unless Signal.list.key?(sig)
          trap(sig) { server.stop }
        end
        # The test waits for this line before making requests.
        STDOUT.puts "OCRAN-RAILS-READY port=\#{port}"
        STDOUT.flush
        server.run.join
      end
    RUBY
  end

  # --- small helpers ---------------------------------------------------

  def write(app, rel, body)
    path = File.join(app, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def edit(app, rel)
    path = File.join(app, rel)
    File.write(path, yield(File.read(path)))
  end

  def run!(cmd, chdir:)
    out, status = Open3.capture2e(*cmd, chdir: chdir)
    return out if status.success?

    raise "#{cmd.join(" ")} failed (#{status.exitstatus}):\n#{out}"
  end
end
