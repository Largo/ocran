$:.unshift File.dirname(__FILE__)
module Foo
  autoload :Bar, 'bar'
end
