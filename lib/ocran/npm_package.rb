# frozen_string_literal: true
require "fileutils"
require "json"
require "timeout"
require "pathname"

module Ocran
  # Fetches files out of a published npm package, which is how both
  # ruby.wasm and PicoRuby distribute their browser runtimes: the prebuilt
  # interpreter (.wasm) and the JavaScript that loads it.
  #
  # The package tarball is downloaded from the npm registry once, checked
  # against the sha512 integrity the registry publishes for it, and the
  # requested files are kept in OCRAN's cache directory, so later builds
  # need no network. A cache filled by hand (the same layout) works offline
  # from the start.
  module NpmPackage
    REGISTRY = "https://registry.npmjs.org"
    MAX_REDIRECTS = 5

    module_function

    # Returns { file => absolute path } for the given files of the package
    # (paths inside the package's tarball, without the leading "package/").
    def fetch(name, version, files, &progress)
      dir = File.join(cache_dir, name.delete_prefix("@").tr("/", "-"), version)
      paths = files.to_h { |file| [file, File.join(dir, file)] }
      return paths if paths.values.all? { |path| File.file?(path) }

      progress&.call("Downloading #{name}@#{version} from the npm registry")
      metadata = JSON.parse(download("#{REGISTRY}/#{name.sub("/", "%2f")}/#{version}"))
      tarball = download(metadata.dig("dist", "tarball") || raise("the registry lists no tarball for #{name}@#{version}"))
      verify(tarball, metadata.dig("dist", "integrity"), "#{name}@#{version}")
      extract(tarball, files, dir)

      missing = paths.reject { |_, path| File.file?(path) }.keys
      raise "#{name}@#{version} does not contain #{missing.join(", ")}" unless missing.empty?

      paths
    rescue SocketError, SystemCallError, IOError, Timeout::Error, JSON::ParserError => e
      raise "Could not download #{name}@#{version} from the npm registry (#{e.class}: #{e.message}). " \
            "Without network access, put the package's #{files.join(", ")} into #{dir}"
    end

    def download(url, redirects = MAX_REDIRECTS)
      require "net/http"
      require "uri"

      uri = URI(url)
      response = Net::HTTP.get_response(uri)
      case response
      when Net::HTTPSuccess
        response.body
      when Net::HTTPRedirection
        raise "too many redirects fetching #{url}" if redirects.zero?

        download(URI.join(url, response["location"]).to_s, redirects - 1)
      else
        raise "#{url} answered #{response.code} #{response.message}"
      end
    end

    def verify(data, integrity, what)
      require "digest"

      algorithm, expected = integrity.to_s.split("-", 2)
      unless algorithm == "sha512" && expected
        raise "the registry publishes no sha512 integrity for #{what}; refusing to use it unverified"
      end
      actual = Digest::SHA512.base64digest(data)
      raise "#{what} does not match the integrity the registry publishes for it" unless actual == expected
    end

    def extract(tarball, files, dir)
      require "rubygems/package"
      require "stringio"
      require "zlib"

      wanted = files.to_h { |file| ["package/#{file}", file] }
      FileUtils.mkdir_p(dir)
      Zlib::GzipReader.wrap(StringIO.new(tarball)) do |gz|
        Gem::Package::TarReader.new(gz) do |tar|
          tar.each do |entry|
            file = wanted[entry.full_name] or next

            path = File.join(dir, file)
            FileUtils.mkdir_p(File.dirname(path))
            # Written under a temporary name first: a half-written file must
            # not pass for a cached one.
            File.binwrite("#{path}.part", entry.read)
            File.rename("#{path}.part", path)
          end
        end
      end
    end

    def cache_dir
      base = ENV["XDG_CACHE_HOME"]
      base = File.join(Dir.home, ".cache") if base.nil? || base.empty?
      File.join(base, "ocran", "npm")
    rescue ArgumentError # Dir.home unavailable (no HOME)
      require "tmpdir"
      File.join(Dir.tmpdir, "ocran-cache", "npm")
    end
  end
end
