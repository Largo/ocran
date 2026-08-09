require 'spec_helper'

describe Text::Table::Cell do
  before(:each) do
    @table = Text::Table.new :rows => [[1, {:value => 2, :colspan => 2}, 3]]
    @cell = @table.text_table_rows.first.cells.first
  end

  it "should be left justified by default" do
    @cell.align.should == :left
  end

  it "should span 1 column by default" do
    @cell.colspan == 1
  end

  it "should return correct column index" do
    @table.text_table_rows.first.cells[0].column_index.should == 0
    @table.text_table_rows.first.cells[1].column_index.should == 1
    @table.text_table_rows.first.cells[2].column_index.should == 3
  end

end

