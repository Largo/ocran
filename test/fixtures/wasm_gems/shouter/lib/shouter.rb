require "shouter/version"

module Shouter
  def self.shout(text)
    "#{text.upcase}! (shouter #{VERSION})"
  end
end
