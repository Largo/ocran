require "json"
require "yaml"

unless defined?(Ocran)
  data = JSON.parse(JSON.generate({ "answer" => 42 }))
  loaded = YAML.safe_load(YAML.dump({ "key" => "value" }))
  puts "json:#{data["answer"]}"
  puts "yaml:#{loaded["key"]}"
  puts "platform:#{RUBY_PLATFORM}"
end
