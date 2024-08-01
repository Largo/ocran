# frozen_string_literal: true
load File.expand_path("../ocran.rb", __dir__)

module Ocran
  module CommandOutput
    def say(s)
      puts "=== #{s}" unless Ocran.option&.quiet?
    end

    def verbose(s)
      puts s if Ocran.option&.verbose?
    end

    def warning(s)
      STDERR.puts "WARNING: #{s}" if Ocran.option&.warning?
    end

    def error(s)
      STDERR.puts "ERROR: #{s}"
    end
  end
end
