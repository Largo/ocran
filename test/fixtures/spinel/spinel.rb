require_relative "greeting"
require "shout"

puts Greeting.new("spinel").text
puts Shout.loud("compiled")
