# HTTPS with certificate verification against the system's trust store.
require "net/http"
require "openssl"
ok = Net::HTTP.start("www.ruby-lang.org", 443, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER) { |h| h.head("/").code }
puts "https=#{ok}"
begin
  Net::HTTP.start("self-signed.badssl.com", 443, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER) { |h| h.head("/") }
  puts "self_signed=accepted"
rescue OpenSSL::SSL::SSLError, SystemCallError
  puts "self_signed=rejected"
end
