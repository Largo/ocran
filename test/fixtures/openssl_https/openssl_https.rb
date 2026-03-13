# encoding: UTF-8
# Set the cert file, so openssl calls work. This needs to be before openssl
ENV['SSL_CERT_FILE'] = File.join(File.dirname(ENV["OCRAN_EXECUTABLE"].to_s), 'cacert.pem')

require "net/http"
require "uri"

uri = URI("https://www.google.com")
response = Net::HTTP.get_response(uri)
raise "HTTPS request failed with status #{response.code}" unless response.is_a?(Net::HTTPSuccess)
puts "SSL connection to #{uri.host} succeeded (HTTP #{response.code})"
