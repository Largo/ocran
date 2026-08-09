require 'integration_helper'

describe Text::Table do
  subject { table.to_s }
  let(:table) { Text::Table.new :rows => @rows, :head => @head, :foot => @foot }

  describe 'first column spanned' do
    context '2 cells wide' do
      before do
        table.rows << [{ :value => 'x', :colspan => 2, :align => align }, 'c', 'd']
      end

      context 'aligned to the left' do
        let(:align) { :left }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          | x           | c    | d    |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end

      context 'center aligned' do
        let(:align) { :center }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          |      x      | c    | d    |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end

      context 'aligned to the right' do
        let(:align) { :right }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          |           x | c    | d    |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end
    end

    context '3 cells wide' do
      before do
        table.rows << [{ :value => 'x', :colspan => 3, :align => align }, 'd']
      end

      context 'aligned to the left' do
        let(:align) { :left }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          | x                  | d    |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end

      context 'center aligned' do
        let(:align) { :center }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          |         x          | d    |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end

      context 'aligned to the right' do
        let(:align) { :right }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          |                  x | d    |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end
    end
  end

  describe 'last column spanned' do
    context '2 cells wide' do
      before do
        table.rows << ['a', 'b', { :value => 'x', :colspan => 2, :align => align }]
      end

      context 'aligned to the left' do
        let(:align) { :left }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          | a    | b    | x           |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end

      context 'center aligned' do
        let(:align) { :center }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          | a    | b    |      x      |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end

      context 'aligned to the right' do
        let(:align) { :right }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          | a    | b    |           x |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end
    end

    context '3 cells wide' do
      before do
        table.rows << ['a', { :value => 'x', :colspan => 3, :align => align }]
      end

      context 'aligned to the left' do
        let(:align) { :left }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          | a    | x                  |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end

      context 'center aligned' do
        let(:align) { :center }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          | a    |         x          |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end

      context 'aligned to the right' do
        let(:align) { :right }

        it { should == deindent(%q{
          +------+------+------+------+
          |  a   |  bb  | ccc  | dddd |
          +------+------+------+------+
          | aa   | bbb  | cccc | d    |
          | aaa  | bbbb | c    | dd   |
          | a    |                  x |
          +------+------+------+------+
          | aaaa | b    | cc   | ddd  |
          +------+------+------+------+
        }) }
      end
    end
  end
end
