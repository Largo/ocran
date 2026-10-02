require_relative "greeter"

greeter = Greeter.new("WebAssembly")
puts greeter.greeting
puts [1, 2, 3].map { |n| n * n }.reduce(0) { |sum, n| sum + n }
