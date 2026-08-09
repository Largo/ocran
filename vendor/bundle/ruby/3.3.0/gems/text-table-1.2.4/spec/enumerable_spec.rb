require 'spec_helper'

describe Enumerable do
  describe Array do
    before(:each) do
      @arr = [
        [11, 2, 3333],
        [44, 56, 6],
        [7, 888, 99],
      ]
    end

    it "to Text::Table" do
      @arr.to_text_table.to_s.should == deindent(%q{
        +----+-----+------+
        | 11 | 2   | 3333 |
        | 44 | 56  | 6    |
        | 7  | 888 | 99   |
        +----+-----+------+
      })
    end

    it "to Text::Table using flat array" do
      [11, 44, 7].to_text_table.to_s.should == deindent(%q{
        +----+
        | 11 |
        | 44 |
        | 7  |
        +----+
      })
    end

    it "to Text::Table, setting first row as head" do
      @arr.to_text_table(:first_row_is_head => true).to_s.should == deindent(%q{
        +----+-----+------+
        | 11 |  2  | 3333 |
        +----+-----+------+
        | 44 | 56  | 6    |
        | 7  | 888 | 99   |
        +----+-----+------+
      })
    end

    it "to Text::Table, setting last row as foot" do
      @arr.to_text_table(:last_row_is_foot => true).to_s.should == deindent(%q{
        +----+-----+------+
        | 11 | 2   | 3333 |
        | 44 | 56  | 6    |
        +----+-----+------+
        | 7  | 888 | 99   |
        +----+-----+------+
      })
    end
  end

  describe Hash do
    before(:each) do
      @hsh = {
        :k  => 'vv',
        'k' =>  :vv
      }
    end
    it "to Text::Table" do
      @hsh.to_text_table.to_s.should == deindent(%q{
        +---+----+
        | k | vv |
        | k | vv |
        +---+----+
      })
    end

    it "to Text::Table, setting first row as head" do
      @hsh.to_text_table(:first_row_is_head => true).to_s.should == deindent(%q{
        +---+----+
        | k | vv |
        +---+----+
        | k | vv |
        +---+----+
      })
    end

    it "to Text::Table, setting last row as foot" do
      @hsh.to_text_table(:last_row_is_foot => true).to_s.should == deindent(%q{
        +---+----+
        | k | vv |
        +---+----+
        | k | vv |
        +---+----+
      })
    end
  end
end

