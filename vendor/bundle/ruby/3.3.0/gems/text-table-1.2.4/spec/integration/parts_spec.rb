require 'integration_helper'

describe Text::Table do
  let(:table) { Text::Table.new :rows => rows, :head => head, :foot => foot }
  let(:rows) { @rows }
  let(:head) { nil }
  let(:foot) { nil }
  subject { table.to_s }

  describe 'rows' do
    it { should == deindent(%q{
      +-----+------+------+----+
      | aa  | bbb  | cccc | d  |
      | aaa | bbbb | c    | dd |
      +-----+------+------+----+
    }) }

    context 'when nothing is passed into the contructor' do
      let(:rows) { nil }

      it 'is an empty array' do
        table.rows.should == []
      end
    end

    context 'with unequal number of cells' do
      pending
    end
  end

  describe 'head' do
    let(:head) { @head }

    it { should == deindent(%q{
      +-----+------+------+------+
      |  a  |  bb  | ccc  | dddd |
      +-----+------+------+------+
      | aa  | bbb  | cccc | d    |
      | aaa | bbbb | c    | dd   |
      +-----+------+------+------+
    }) }
  end

  describe 'foot' do
    let(:foot) { @foot }

    it { should == deindent(%q{
      +------+------+------+-----+
      | aa   | bbb  | cccc | d   |
      | aaa  | bbbb | c    | dd  |
      +------+------+------+-----+
      | aaaa | b    | cc   | ddd |
      +------+------+------+-----+
    }) }
  end

  describe 'separators' do
    let(:rows) { @rows.insert(1, :separator) }

    it { should == deindent(%q{
      +-----+------+------+----+
      | aa  | bbb  | cccc | d  |
      +-----+------+------+----+
      | aaa | bbbb | c    | dd |
      +-----+------+------+----+
    }) }
  end
end
