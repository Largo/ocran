# OCRAN loads every autoload constant it finds; this one aborts, as
# rdoc/servlet.rb does when webrick is missing. The build must go on.
module OptionalFeature
  autoload :Server, File.join(__dir__, "optional_server.rb")
end
puts "autoloadexit ok"
