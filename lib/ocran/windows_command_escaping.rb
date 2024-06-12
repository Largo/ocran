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

    def convert_path_to_windows(s)
      s.to_s.gsub(File::SEPARATOR, "\\")
    end
  end
end
