# Copyright (c) 2021-2022 Andy Maleh
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require 'perfect_shape/ellipse'

module PerfectShape
  class Circle < Ellipse
    MESSAGE_WIDTH_AND_HEIGHT_AND_DIAMETER_NOT_EQUAL = 'Circle width, height, and diameter must all be equal if more than one is specified; or otherwise keep only one of them in arguments!'
    MESSAGE_RADIUS_X_AND_RADIUS_Y_AND_RADIUS_NOT_EQUAL = 'Circle radius_x, radius_y, and radius must all be equal if more than one is specified; or otherwise keep only one of them in arguments!'
    
    def initialize(x: 0, y: 0, width: nil, height: nil, diameter: nil, center_x: nil, center_y: nil, radius_x: nil, radius_y: nil, radius: nil)
      raise MESSAGE_WIDTH_AND_HEIGHT_AND_DIAMETER_NOT_EQUAL if (diameter && width && diameter != width) || (diameter && height && diameter != height) || (width && height && width != height)
      raise MESSAGE_RADIUS_X_AND_RADIUS_Y_AND_RADIUS_NOT_EQUAL if (radius && radius_x && radius != radius_x) || (radius && radius_y && radius != radius_y) || (radius_x && radius_y && radius_x != radius_y)
      if center_x && center_y && (radius || radius_x || radius_y)
        radius ||= radius_x || radius_y
        self.radius = radius
        super(center_x: center_x, center_y: center_y, radius_x: self.radius_x, radius_y: self.radius_y)
      else
        diameter ||= width || height || 1
        self.diameter = diameter
        super(x: x, y: y, width: self.width, height: self.height)
      end
    end
    
    def diameter
      @radius ? @radius * BigDecimal('2.0') : @diameter
    end
    
    def radius
      @diameter ? @diameter / BigDecimal('2.0') : @radius
    end
    
    # Sets length, normalizing to BigDecimal
    def diameter=(value)
      @diameter = BigDecimal(value.to_s)
      @radius = nil
      self.width = @diameter unless width == @diameter
      self.height = @diameter unless height == @diameter
    end
    
    # Sets radius, normalizing to BigDecimal
    def radius=(value)
      @radius = BigDecimal(value.to_s)
      @diameter = nil
      self.radius_x = @radius unless @width == @radius
      self.radius_y = @radius unless @height == @radius
    end
    
    def width=(value)
      super
      self.diameter = @width unless diameter == @width
      self.height = @width unless height == @width
    end
    
    def height=(value)
      super
      self.diameter = @height unless diameter == @height
      self.width = @height unless width == @height
    end
    
    def radius_x=(value)
      super
      self.radius = @radius_x unless radius == @radius_x
      self.radius_y = @radius_x unless radius_y == @radius_x
    end
    
    def radius_y=(value)
      super
      self.radius = @radius_y unless radius == @radius_y
      self.radius_x = @radius_y unless radius_x == @radius_y
    end
  end
end
