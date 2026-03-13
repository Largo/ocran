# Use the cacert.pem bundled next to the exe.
# This must be set before OpenSSL is loaded.
ENV["SSL_CERT_FILE"] = File.join(File.dirname(ENV["OCRAN_EXECUTABLE"].to_s), "cacert.pem")

require "net/http"
require "uri"

uri = URI("https://github.com")
response = Net::HTTP.get_response(uri)
raise "HTTPS request failed with status #{response.code}" unless response.is_a?(Net::HTTPSuccess)
puts "SSL connection to #{uri.host} succeeded (HTTP #{response.code})" unless defined?(Ocran)
