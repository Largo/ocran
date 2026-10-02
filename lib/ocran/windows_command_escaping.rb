# frozen_string_literal: true
require "pathname"
require_relative "build_constants"

module Ocran
  module WindowsCommandEscaping
    # The extraction root placeholder (see BuildConstants) at the start of a
    # packed path, with either separator.
    EXTRACT_ROOT_PREFIX = %r{#{Regexp.escape(BuildConstants::EXTRACT_ROOT.to_s)}[/\\]}

    module_function

    def escape_double_quotes(s)
      s.to_s.gsub('"', '""')
    end

    def quote_and_escape(s)
      "\"#{escape_double_quotes(s)}\""
    end

    # Doubles percent signs so that cmd.exe does not expand text between
    # them as a variable reference when the string is part of a batch file.
    def escape_percent(s)
      s.to_s.gsub("%", "%%")
    end

    # Renders a build-time value for a batch file, for use inside double
    # quotes: percent signs are escaped so cmd.exe takes the value literally,
    # then the extraction root placeholder becomes +root+, a batch
    # expression for the application directory that ends in a backslash
    # (e.g. "%~dp0").
    def batch_value(s, root)
      escape_percent(s).gsub(EXTRACT_ROOT_PREFIX) { root }
    end
  end
end
