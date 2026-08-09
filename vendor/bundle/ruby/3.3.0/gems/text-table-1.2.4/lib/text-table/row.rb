module Text #:nodoc:
  class Table

    # A Text::Table::Row belongs to a Text::Table object and can have many Text::Table::Cell objects.
    # It handles the rendering of rows and inserted separators.
    #
    class Row
      attr_reader :table #:nodoc:
      attr_reader :cells #:nodoc:

      def initialize(row_input, table) #:nodoc:
        @table = table
        row_input = [row_input].flatten
        @cells = row_input.first == :separator ? :separator : row_input.map do |cell_input|
          Cell.new(cell_input.is_a?(Hash) ? cell_input.merge(:row => self) : {:value => cell_input}.merge(:row => self))
        end
      end

      def to_s #:nodoc:
        if cells == :separator
          table.separator
        else
          ([table.horizontal_boundary] * 2).join(
            cells.map(&:to_s).join(table.horizontal_boundary)
          ) + "\n"
        end
      end

    end
  end
end