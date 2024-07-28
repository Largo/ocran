# frozen_string_literal: true

module Ocran
  module CommandOutput
    def say(s)
      puts "=== #{s}" unless Ocran.quiet?
    end

    def verbose(s)
      puts s if Ocran.verbose?
    end

    def warning(s)
      STDERR.puts "WARNING: #{s}" if Ocran.warning?
    end

    def error(s)
      STDERR.puts "ERROR: #{s}"
    end
  end
end
