require "net/http"
require "uri"
require "openssl"

uri = URI("https://github.com")
response = Net::HTTP.get_response(uri)
raise "HTTPS request failed with status #{response.code}" unless response.is_a?(Net::HTTPSuccess)

unless defined?(Ocran)
  puts "SSL connection to #{uri.host} succeeded (HTTP #{response.code})"
  # Write the cert file path actually used so the test can verify it is bundled
  # inside the OCRAN extraction directory.
  # OCRAN sets SSL_CERT_FILE to the extracted cert; fall back to DEFAULT_CERT_FILE.
  cert_in_use = ENV["SSL_CERT_FILE"] || OpenSSL::X509::DEFAULT_CERT_FILE
  File.write("cert_path.txt", cert_in_use)
end
