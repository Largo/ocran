# frozen_string_literal: true

module Ocran
  module WindowsCommandEscaping
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
  end
end
