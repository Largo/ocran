require "bundler/setup"
require "shouter"
require "json"

puts Shouter.shout("hello from a gem")
puts JSON.generate(gems: $LOAD_PATH.grep(/shouter/).size)
