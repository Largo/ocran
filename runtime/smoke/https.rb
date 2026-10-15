# HTTPS with certificate verification against the system's trust store.
require "net/http"
require "openssl"

# Network trouble is retried and, if it persists, reported as
# "unreachable" (which fails the check): only a TLS error is a rejection.
def https(host)
  attempts = 0
  begin
    Net::HTTP.start(host, 443, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER,
                               open_timeout: 15, read_timeout: 15) { |h| yield h }
  rescue OpenSSL::SSL::SSLError
    raise
  rescue IO::TimeoutError, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => e
    attempts += 1
    retry if attempts < 3 && sleep(2 * attempts)
    warn "#{host}: #{e.class}: #{e.message}"
    :unreachable
  end
end

puts "https=#{https("www.ruby-lang.org") { |h| h.head("/").code }}"
result = begin
  https("self-signed.badssl.com") { |h| h.head("/") } == :unreachable ? "unreachable" : "accepted"
rescue OpenSSL::SSL::SSLError
  "rejected"
end
puts "self_signed=#{result}"
