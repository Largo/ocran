require "net/http"
require "uri"
return if defined?(Ocran)

# SSL_CERT_FILE must be set before openssl initializes. net/http uses
# `autoload :OpenSSL` so the library is not loaded until the first HTTPS
# connection; setting the env var here ensures OpenSSL picks it up when
# Net::HTTP.get_response triggers the autoload.
ENV["SSL_CERT_FILE"] = File.join(File.dirname(ENV["OCRAN_EXECUTABLE"].to_s), "cacert.pem")

uri = URI("https://github.com")
response = Net::HTTP.get_response(uri)
raise "HTTPS request failed with status #{response.code}" unless response.is_a?(Net::HTTPSuccess)
puts "SSL connection to #{uri.host} succeeded (HTTP #{response.code})"
