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
require 'perfect_shape/point'
require 'perfect_shape/line'
require 'perfect_shape/quadratic_bezier_curve'
require 'perfect_shape/cubic_bezier_curve'
require 'perfect_shape/multi_point'

module PerfectShape
  # A composite of multiple shapes
  class CompositeShape < Shape
    include Equalizer.new(:shapes)
    
    attr_accessor :shapes
    
    # Constructs from multiple shapes
    def initialize(shapes: [])
      self.shapes = shapes
    end
    
    def min_x
      shapes.map(&:min_x).min
    end
    
    def min_y
      shapes.map(&:min_y).min
    end
    
    def max_x
      shapes.map(&:max_x).max
    end
    
    def max_y
      shapes.map(&:max_y).max
    end
    
    # Checks if composite shape contains point (two-number Array or x, y args)
    # by comparing against all shapes it consists of
    #
    # @param x The X coordinate of the point to test.
    # @param y The Y coordinate of the point to test.
    #
    # @return true if the point lies within the bound of
    # the composite shape or false if the point lies outside of the
    # path's bounds.
    def contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      
      shapes.any? { |shape| shape.contain?(x, y, outline: outline, distance_tolerance: distance_tolerance) }
    end
    
    def intersect?(rectangle)
      shapes.any? { |shape| shape.intersect?(rectangle) }
    end
  end
end
