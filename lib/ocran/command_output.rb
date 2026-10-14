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

    # Progress goes to stdout, which is buffered when it is not a terminal:
    # flushed first, so that a warning or an error shows up after what led
    # to it when both streams go to the same log.
    def warning(s)
      return unless Ocran.option&.warning?

      $stdout.flush
      STDERR.puts "WARNING: #{s}"
    end

    def error(s)
      $stdout.flush
      STDERR.puts "ERROR: #{s}"
    end
  end
end
