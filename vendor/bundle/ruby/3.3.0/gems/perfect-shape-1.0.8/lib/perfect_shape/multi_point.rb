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

module PerfectShape
  # Represents multi-point shapes like Line, Polygon, and Polyline
  module MultiPoint
    class << self
      def normalize_point_array(the_points)
        if the_points.all? {|the_point| the_point.is_a?(Array)}
          the_points
        else
          the_points = the_points.flatten
          xs = the_points.each_with_index.select {|n, i| i.even?}.map(&:first)
          ys = the_points.each_with_index.select {|n, i| i.odd?}.map(&:first)
          xs.zip(ys)
        end
      end
    end
  
    attr_reader :points
    
    def initialize(points: [])
      self.points = points
    end
    
    # Sets points, normalizing to an Array of Arrays of (x,y) pairs as BigDecimal
    def points=(the_points)
      the_points = MultiPoint.normalize_point_array(the_points)
      @points = the_points.map do |pair|
        [
          pair.first.is_a?(BigDecimal) ? pair.first : BigDecimal(pair.first.to_s),
          pair.last.is_a?(BigDecimal) ? pair.last : BigDecimal(pair.last.to_s)
        ]
      end
      @points
    end
    
    def first_point
      points.first.to_a
    end
    
    def min_x
      points.map(&:first).min
    end
    
    def min_y
      points.map(&:last).min
    end
    
    def max_x
      points.map(&:first).max
    end
    
    def max_y
      points.map(&:last).max
    end
  end
end
