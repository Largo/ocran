module Enumerable

  # Returns a new Text::Table object with the elements as the rows.
  #
  # ==== Options
  # <tt>:first_row_is_head</tt>:: when set to <tt>true</tt>, the first row becomes the table heading
  # <tt>:last_row_is_foot</tt>:: when set to <tt>true</tt>, the last row becomes the table footer
  #
  # ==== Examples
  #
  #      require 'rubygems'
  #      require 'text-table'
  #
  #      array = [
  #        ['Student', 'Mid-Terms', 'Finals'],
  #        ['Sam', 94, 93],
  #        ['Jane', 92, 99],
  #        ['Average', 93, 96]
  #      ]
  #
  #      puts array.to_text_table
  #
  #      #    +---------+-----------+--------+
  #      #    | Student | Mid-Terms | Finals |
  #      #    | Sam     | 94        | 93     |
  #      #    | Jane    | 92        | 99     |
  #      #    | Average | 93        | 96     |
  #      #    +---------+-----------+--------+
  #
  #      puts array.to_text_table(:first_row_is_head => true)
  #
  #      #    +---------+-----------+--------+
  #      #    | Student | Mid-Terms | Finals |
  #      #    +---------+-----------+--------+
  #      #    | Sam     | 94        | 93     |
  #      #    | Jane    | 92        | 99     |
  #      #    | Average | 93        | 96     |
  #      #    +---------+-----------+--------+
  #
  #      puts array.to_text_table(:first_row_is_head => true, :last_row_is_foot => true)
  #
  #      #    +---------+-----------+--------+
  #      #    | Student | Mid-Terms | Finals |
  #      #    +---------+-----------+--------+
  #      #    | Sam     | 94        | 93     |
  #      #    | Jane    | 92        | 99     |
  #      #    +---------+-----------+--------+
  #      #    | Average | 93        | 96     |
  #      #    +---------+-----------+--------+
  #
  def to_text_table(options = {})
    table = Text::Table.new :rows => self.to_a.dup
    table.head = table.rows.shift if options[:first_row_is_head]
    table.foot = table.rows.pop   if options[:last_row_is_foot]
    table
  end
  alias_method :to_table, :to_text_table unless method_defined? :to_table
end