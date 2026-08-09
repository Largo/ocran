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
require 'perfect_shape/point_location'

module PerfectShape
  # Point class includes point-specific operations like `#==`, `point_distance` and a fuzzy `contain?` matcher
  class Point < Shape
    class << self
      def point_distance(x, y, px, py)
        x = x.is_a?(BigDecimal) ? x : BigDecimal(x.to_s)
        y = y.is_a?(BigDecimal) ? y : BigDecimal(y.to_s)
        px = px.is_a?(BigDecimal) ? px : BigDecimal(px.to_s)
        py = py.is_a?(BigDecimal) ? py : BigDecimal(py.to_s)
        BigDecimal(Math.sqrt((px - x)**2 + (py - y)**2).to_s)
      end
      
      # Normalizes point args whether two-number Array or x, y args returning
      # normalized point array of two BigDecimal's
      #
      # @param x_or_point The point or X coordinate of the point to test.
      # @param y The Y coordinate of the point to test.
      #
      # @return Array of x and y BigDecimal's representing point
      def normalize_point(x_or_point, y = nil)
        x = x_or_point
        x, y = x if y.nil? && x_or_point.is_a?(Array) && x_or_point.size == 2
        x = x.is_a?(BigDecimal) ? x : BigDecimal(x.to_s)
        y = y.is_a?(BigDecimal) ? y : BigDecimal(y.to_s)
        [x, y]
      end
    end
    
    include PointLocation
    include Equalizer.new(:x, :y)
    
    def initialize(x_or_point = nil, y_arg = nil, x: nil, y: nil)
      if x_or_point.is_a?(Array)
        x, y = x_or_point
        super(x: x, y: y)
      elsif x_or_point && y_arg
        super(x: x_or_point, y: y_arg)
      else
        x ||= 0
        y ||= 0
        super(x: x, y: y)
      end
    end
    
    def max_x
      x
    end
    
    def max_y
      y
    end
    
    # Checks if points match, with distance tolerance (0 by default)
    #
    # @param x The X coordinate of the point to test.
    # @param y The Y coordinate of the point to test.
    # @param distance_tolerance The distance from point to tolerate (0 by default)
    #
    # @return true if the point is close enough within distance tolerance,
    # false if the point is too far.
    def contain?(x_or_point, y = nil, outline: true, distance_tolerance: 0)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      distance_tolerance = BigDecimal(distance_tolerance.to_s)
      point_distance(x, y) <= distance_tolerance
    end
    
    def point_distance(x_or_point, y = nil)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      
      Point.point_distance(self.x, self.y, x, y)
    end
    
    def intersect?(rectangle)
      rectangle.contain?(self.to_a)
    end
    
    # Convert to pair Array of x,y coordinates
    def to_a
      [self.x, self.y]
    end
  end
end
