module ZipApp
  # Reads a data file that ships INSIDE the package, addressed relative to
  # this source file. It only works if __dir__ points at the packed copy.
  module Greeter
    DATA_FILE = File.expand_path("../../data/message.txt", __dir__)

    def self.message = File.read(DATA_FILE).strip
  end
end
