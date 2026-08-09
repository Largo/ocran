require 'integration_helper'

describe Text::Table do
  let(:table) { Text::Table.new :rows => @rows, :head => @head, :foot => @foot,
                :horizontal_boundary => horizontal_boundary,
                :vertical_boundary => vertical_boundary,
                :boundary_intersection => boundary_intersection,
                :horizontal_padding => horizontal_padding }
  let(:horizontal_boundary)   { nil }
  let(:vertical_boundary)     { nil }
  let(:boundary_intersection) { nil }
  let(:horizontal_padding) { nil }
  subject { table.to_s }

  describe 'horizontal boundaries' do
    context 'when ":"' do
      let(:horizontal_boundary) { ':' }

      it { should == deindent(%q{
        +------+------+------+------+
        :  a   :  bb  : ccc  : dddd :
        +------+------+------+------+
        : aa   : bbb  : cccc : d    :
        : aaa  : bbbb : c    : dd   :
        +------+------+------+------+
        : aaaa : b    : cc   : ddd  :
        +------+------+------+------+
      }) }
    end

    context 'when "||" and boundary intersection is "++"' do
      let(:horizontal_boundary) { '||' }
      let(:boundary_intersection) { '++' }

      it { should == deindent(%q{
        ++------++------++------++------++
        ||  a   ||  bb  || ccc  || dddd ||
        ++------++------++------++------++
        || aa   || bbb  || cccc || d    ||
        || aaa  || bbbb || c    || dd   ||
        ++------++------++------++------++
        || aaaa || b    || cc   || ddd  ||
        ++------++------++------++------++
      }) }

      context 'with spanned cells' do
        before do
          table.rows << :separator
          table.rows << [{ :value => 'x', :colspan => 2, :align => :right }, 'c', 'd']
        end

        it { should == deindent(%q{
          ++------++------++------++------++
          ||  a   ||  bb  || ccc  || dddd ||
          ++------++------++------++------++
          || aa   || bbb  || cccc || d    ||
          || aaa  || bbbb || c    || dd   ||
          ++------++------++------++------++
          ||            x || c    || d    ||
          ++------++------++------++------++
          || aaaa || b    || cc   || ddd  ||
          ++------++------++------++------++
        }) }
      end

    end
  end

  describe 'vertical boundaries when "="' do
    let(:vertical_boundary) { '=' }

    it { should == deindent(%q{
      +======+======+======+======+
      |  a   |  bb  | ccc  | dddd |
      +======+======+======+======+
      | aa   | bbb  | cccc | d    |
      | aaa  | bbbb | c    | dd   |
      +======+======+======+======+
      | aaaa | b    | cc   | ddd  |
      +======+======+======+======+
    }) }
  end

  describe 'boundary intersections when "*"' do
    let(:boundary_intersection) { '*' }

    it { should == deindent(%q{
        *------*------*------*------*
        |  a   |  bb  | ccc  | dddd |
        *------*------*------*------*
        | aa   | bbb  | cccc | d    |
        | aaa  | bbbb | c    | dd   |
        *------*------*------*------*
        | aaaa | b    | cc   | ddd  |
        *------*------*------*------*
    }) }
  end

  describe 'horizantal padding when 3 spaces' do
    let(:horizontal_padding) { 3 }

    it { should == deindent(%q{
      +----------+----------+----------+----------+
      |    a     |    bb    |   ccc    |   dddd   |
      +----------+----------+----------+----------+
      |   aa     |   bbb    |   cccc   |   d      |
      |   aaa    |   bbbb   |   c      |   dd     |
      +----------+----------+----------+----------+
      |   aaaa   |   b      |   cc     |   ddd    |
      +----------+----------+----------+----------+
    }) }
  end
end
