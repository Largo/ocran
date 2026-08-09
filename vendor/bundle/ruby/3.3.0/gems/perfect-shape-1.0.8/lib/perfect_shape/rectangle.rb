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

require 'perfect_shape/shape'
require 'perfect_shape/rectangular_shape'
require 'perfect_shape/point'
require 'perfect_shape/line'

module PerfectShape
  class Rectangle < Shape
    include RectangularShape
    include Equalizer.new(:x, :y, :width, :height)
    
    # bitmask indicating a point lies to the left
    OUT_LEFT = 1

    # bitmask indicating a point lies above
    OUT_TOP = 2

    # bitmask indicating a point lies to the right
    OUT_RIGHT = 4

    # bitmask indicating a point lies below
    OUT_BOTTOM = 8
        
    RECT_INTERSECTS = 0x80000000
        
    # Checks if rectangle contains point (two-number Array or x, y args)
    #
    # @param x The X coordinate of the point to test.
    # @param y The Y coordinate of the point to test.
    #
    # @return true if the point lies within the bound of
    # the rectangle, false if the point lies outside of the
    # rectangle's bounds.
    def contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      
      if outline
        edges.any? { |edge| edge.contain?(x, y, distance_tolerance: distance_tolerance) }
      else
        x.between?(self.x, self.x + width) && y.between?(self.y, self.y + height)
      end
    end
    
    def edges
      [
        Line.new(points: [[self.x, self.y], [self.x + width, self.y]]),
        Line.new(points: [[self.x + width, self.y], [self.x + width, self.y + height]]),
        Line.new(points: [[self.x + width, self.y + height], [self.x, self.y + height]]),
        Line.new(points: [[self.x, self.y + height], [self.x, self.y]])
      ]
    end
    
    # Returns out state for specified point (x,y): (left, right, top, bottom)
    #
    # It can be 0 meaning not outside the rectangle,
    # or if outside the rectangle, then a bit mask
    # combination of OUT_LEFT, OUT_RIGHT, OUT_TOP, or OUT_BOTTOM
    def out_state(x_or_point, y = nil)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      
      out = 0
      if self.width <= 0
          out |= OUT_LEFT | OUT_RIGHT
      elsif x < self.x
          out |= OUT_LEFT
      elsif x > self.x + self.width
          out |= OUT_RIGHT
      end
      if self.height <= 0
          out |= OUT_TOP | OUT_BOTTOM
      elsif y < self.y
          out |= OUT_TOP
      elsif y > self.y + self.height
          out |= OUT_BOTTOM
      end
      out
    end
    
    # A rectangle is empty if its width or height is 0 (or less)
    def empty?
      width <= 0.0 || height <= 0.0
    end
    
    def intersect?(rectangle)
      x = rectangle.x
      y = rectangle.y
      w = rectangle.width
      h = rectangle.height
      return false if empty? || w <= 0 || h <= 0
      x0 = self.x
      y0 = self.y
      (x + w) > x0 &&
        (y + h) > y0 &&
        x < (x0 + self.width) &&
        y < (y0 + self.height)
    end
    
    # Converts Rectangle into basic Path shapes made up of Points and Lines
    # Used by Path when adding a Rectangle to Path shapes
    def to_path_shapes
      path_shapes = []
      x = self.x
      y = self.y
      w = self.width
      h = self.height
      index = 0
      index = 5 if (w < 0 || h < 0)
      max_index = 4
      max_index = 2 if (w == 0 && h > 0) || (w > 0 && h == 0)
      max_index = 1 if (w == 0 && h == 0)
      first_point_x = first_point_y = nil
      
      until index > max_index
        if index == max_index
          path_shapes << Line.new(points: [[first_point_x, first_point_y]])
        else
          coords = []
          coords[0] = x
          coords[1] = y
          coords[0] += w if ([2, 4].include?(max_index) && index == 1) || (max_index == 4 && index == 2)
          coords[1] += h if (max_index == 2 && index == 1) || (max_index == 4 && [2, 3].include?(index))
          if index == 0
            first_point_x = coords[0]
            first_point_y = coords[1]
            path_shapes << Point.new(coords)
          else
            path_shapes << Line.new(points: coords)
          end
        end
        index += 1
      end
      
      path_shapes
    end
  end
end
