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
    write_openssl_gap(app)
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
    # `rails new` writes an encrypted credentials file and its master key.
    # Neither belongs in a package: the master key would be handed to
    # everyone who gets the executable, and reading the file needs
    # AES-256-GCM, which the cosmopolitan Ruby's openssl does not have
    # (see write_openssl_gap and the Rails section of README.md). The
    # application takes its secret from SECRET_KEY_BASE instead, which
    # server.rb sets.
    FileUtils.rm_f([File.join(app, "config/credentials.yml.enc"),
                    File.join(app, "config/master.key")])

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
            # Rails' default session store encrypts the session cookie with
            # AES-256-GCM. Under a Ruby whose openssl has no symmetric
            # ciphers - the cosmopolitan one - that is not available at any
            # price, so keep the session server-side and put only its id in
            # the cookie. Everything else (the CSRF token in the session,
            # the signed parts of the cookie jar) then needs no more than
            # the HMAC the gap shim supplies.
            unless OpensslGap.ciphers?
              config.session_store :cache_store, key: "_demo_session"
            end
            config.load_defaults
      RUBY
    end
  end

  # A file the application loads before Rails, which fills in what is
  # missing from the cosmopolitan Ruby's openssl.
  #
  # That openssl is a shim over MbedTLS with no Cipher, no HMAC, no
  # PBKDF2 and no OpenSSL.fixed_length_secure_compare, and no
  # OpenSSL::Digest class hierarchy - and Rails does not merely use those,
  # it mentions them at load time: `require "rails"` alone dies on
  # `OpenSSLCipherError = OpenSSL::Cipher::CipherError` in
  # ActiveSupport::MessageEncryptor. Everything this file adds except
  # Cipher is the real algorithm on top of Ruby's own Digest (checked
  # against the host OpenSSL); Cipher deliberately is not - a fake cipher
  # would be worse than none - it exists so that Rails can name the
  # constant, and raises if anything ever tries to encrypt with it.
  #
  # On a Ruby with a complete openssl every branch here is skipped, so the
  # same file is loaded by both the native and the cosmopolitan build.
  def write_openssl_gap(app)
    write(app, "openssl_gap.rb", <<~'RUBY')
      # frozen_string_literal: true
      #
      # Fills the gaps in the cosmopolitan Ruby's MbedTLS-backed openssl
      # shim. Written by OCRAN's test/rails_app_generator.rb; see the
      # Rails section of OCRAN's README.md.
      require "openssl"
      require "digest"

      module OpensslGap
        # Whether this Ruby's openssl can actually encrypt.
        def self.ciphers?
          OpenSSL::Cipher.new("aes-256-gcm")
          true
        rescue StandardError, NotImplementedError
          false
        end
      end

      module OpenSSL
        unless respond_to?(:fixed_length_secure_compare)
          # Constant-time comparison of two equal-length strings.
          def self.fixed_length_secure_compare(a, b)
            a = a.to_s.b
            b = b.to_s.b
            raise ArgumentError, "inputs must be of equal length" unless a.bytesize == b.bytesize

            result = 0
            a.each_byte.zip(b.each_byte) { |x, y| result |= x ^ y }
            result.zero?
          end
        end

        # ActiveSupport::KeyGenerator refuses any digest that is not an
        # OpenSSL::Digest subclass, so a module of aliases for ::Digest is
        # not enough: this has to be a real class hierarchy. The digests
        # themselves are Ruby's own, i.e. genuine SHA-2 and MD5.
        unless const_defined?(:Digest, false) && const_get(:Digest, false).is_a?(Class)
          send(:remove_const, :Digest) if const_defined?(:Digest, false)

          class Digest < ::Digest::Class
            class DigestError < OpenSSLError; end

            ALGORITHMS = {
              "MD5" => ["digest/md5", "MD5"],
              "SHA1" => ["digest/sha1", "SHA1"],
              "SHA256" => ["digest/sha2", "SHA256"],
              "SHA384" => ["digest/sha2", "SHA384"],
              "SHA512" => ["digest/sha2", "SHA512"],
            }.freeze

            # "sha-256", "SHA2-256" and "SHA256" all name one digest.
            ALIASES = { "SHA2256" => "SHA256", "SHA2384" => "SHA384", "SHA2512" => "SHA512" }.freeze

            def self.backend(name)
              key = name.to_s.upcase.delete("-_")
              key = ALIASES.fetch(key, key)
              feature, const = ALGORITHMS[key]
              raise DigestError, "unsupported digest algorithm: #{name}" unless feature

              require feature
              [::Digest.const_get(const), key]
            end

            def initialize(name, data = nil)
              backend, @name = self.class.backend(name)
              @md = backend.new
              update(data) if data
            end

            def initialize_copy(other)
              super
              @md = other.instance_variable_get(:@md).clone
            end

            def update(data)
              @md.update(data)
              self
            end
            alias << update

            def reset
              @md.reset
              self
            end

            def finish = @md.digest
            def digest_length = @md.digest_length
            def block_length = @md.block_length
            attr_reader :name
          end

          Digest::ALGORITHMS.each_key do |algorithm|
            Digest.const_set(algorithm, Class.new(Digest) do
              define_method(:initialize) { |data = nil| super(algorithm, data) }
            end)
          end
        end

        # HMAC (RFC 2104) over those digests. ActiveSupport::MessageVerifier
        # signs every signed cookie with this.
        unless const_defined?(:HMAC, false)
          class HMAC
            def self.digest(digest, key, data) = new(key, digest).update(data).digest
            def self.hexdigest(digest, key, data) = digest(digest, key, data).unpack1("H*")

            def initialize(key, digest)
              @digest = digest.is_a?(String) || digest.is_a?(Symbol) ? OpenSSL::Digest.new(digest) : digest
              block = @digest.block_length
              key = key.to_s.b
              key = fresh.update(key).digest if key.bytesize > block
              key = key.ljust(block, "\0")
              @ipad = xor(key, 0x36)
              @opad = xor(key, 0x5c)
              reset
            end

            def update(data)
              @inner.update(data)
              self
            end
            alias << update

            def reset
              @inner = fresh.update(@ipad)
              self
            end

            def digest = fresh.update(@opad).update(@inner.clone.digest).digest
            def hexdigest = digest.unpack1("H*")

            private

            def fresh = @digest.clone.reset
            def xor(key, byte) = key.each_byte.map { |b| b ^ byte }.pack("C*")
          end
        end

        # PBKDF2 (RFC 8018), which ActiveSupport::KeyGenerator derives every
        # key Rails signs with from secret_key_base.
        unless const_defined?(:KDF, false)
          module KDF
            class KDFError < OpenSSLError; end

            def self.pbkdf2_hmac(pass, salt:, iterations:, length:, hash:)
              prf = hash.is_a?(String) || hash.is_a?(Symbol) ? OpenSSL::Digest.new(hash) : hash
              raise KDFError, "invalid length" if length.negative?

              out = +"".b
              block = 1
              while out.bytesize < length
                u = OpenSSL::HMAC.digest(prf, pass, "#{salt}#{[block].pack("N")}")
                t = u.dup
                (iterations - 1).times do
                  u = OpenSSL::HMAC.digest(prf, pass, u)
                  t = t.each_byte.zip(u.each_byte).map { |a, b| a ^ b }.pack("C*")
                end
                out << t
                block += 1
              end
              out[0, length]
            end
          end
        end

        unless const_defined?(:PKCS5, false)
          module PKCS5
            def self.pbkdf2_hmac(pass, salt, iter, keylen, digest)
              KDF.pbkdf2_hmac(pass, salt: salt, iterations: iter, length: keylen, hash: digest)
            end
          end
        end

        # Not an implementation: a placeholder so that the constant Rails
        # names at load time exists. Anything that actually tries to
        # encrypt gets a clear error instead of fake ciphertext.
        unless const_defined?(:Cipher, false)
          class Cipher
            class CipherError < OpenSSLError; end

            def self.ciphers = []

            def initialize(name)
              raise CipherError, "this Ruby's openssl provides no symmetric ciphers (#{name})"
            end
          end
        end
      end
    RUBY
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
      # Required, not optional: the packaged application ships no
      # config/credentials.yml.enc (see rails_app_generator.rb), so this is
      # where Rails' secret comes from. Reading credentials would need
      # AES-256-GCM, which the cosmopolitan Ruby's openssl does not have.
      # A real application would take this from its environment rather
      # than hardcode it.
      ENV["SECRET_KEY_BASE"] ||= "0" * 64
      ENV["DATABASE_URL"]    ||= "sqlite3:\#{File.join(data_dir, "demo.sqlite3")}"
      ENV["RAILS_DEMO_TMP"]  ||= File.join(data_dir, "tmp")
      FileUtils.mkdir_p(ENV["RAILS_DEMO_TMP"])

      #{UNLOADED_RUNTIME_DEPS}
      # Before Rails: `require "rails"` itself needs OpenSSL::Cipher to
      # exist, which under the cosmopolitan Ruby it does not. A no-op on
      # a Ruby with a complete openssl.
      require_relative "openssl_gap"

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
