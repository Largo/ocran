require "mime/types"

unless defined?(Ocran)
  puts "gem:#{MIME::Types["text/plain"].first.preferred_extension}"
  puts "platform:#{RUBY_PLATFORM}"
end
