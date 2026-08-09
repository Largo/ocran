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
require 'perfect_shape/arc'
require 'perfect_shape/ellipse'
require 'perfect_shape/circle'
require 'perfect_shape/rectangle'
require 'perfect_shape/square'
require 'perfect_shape/multi_point'

module PerfectShape
  class Path < Shape
    include MultiPoint
    include Equalizer.new(:shapes, :closed, :winding_rule)
    
    # Available class types for path shapes
    SHAPE_TYPES = [Array, PerfectShape::Point, PerfectShape::Line, PerfectShape::QuadraticBezierCurve, PerfectShape::CubicBezierCurve, PerfectShape::Arc, PerfectShape::Ellipse, PerfectShape::Circle, PerfectShape::Rectangle, PerfectShape::Square]
    
    # Available winding rules
    WINDING_RULES = [:wind_even_odd, :wind_non_zero]
    
    attr_reader :winding_rule
    attr_accessor :shapes, :closed, :line_to_complex_shapes
    alias closed? closed
    alias line_to_complex_shapes? line_to_complex_shapes
    
    # Constructs Path with winding rule, closed status, line_to_complex_shapes option, and shapes (must always start with PerfectShape::Point or Array of [x,y] coordinates)
    # Shape class types can be any of SHAPE_TYPES: Array (x,y coordinates), PerfectShape::Point, PerfectShape::Line, PerfectShape::QuadraticBezierCurve, PerfectShape::CubicBezierCurve
    # PerfectShape::Arc, PerfectShape::Ellipse, or PerfectShape::Circle
    # Complex shapes, meaning Arc, Ellipse, and Circle, are decomposed into basic path shapes, meaning Point, Line, QuadraticBezierCurve, and CubicBezierCurve.
    # winding_rule can be any of WINDING_RULES: :wind_non_zero (default) or :wind_even_odd
    # closed can be true or false (default)
    # line_to_complex_shapes can be true or false (default), indicating whether to connect to complex shapes,
    # meaning Arc, Ellipse, and Circle, with a line, or otherwise move to their start point instead.
    def initialize(shapes: [], closed: false, winding_rule: :wind_even_odd, line_to_complex_shapes: false)
      self.closed = closed
      self.winding_rule = winding_rule
      self.shapes = shapes
      self.line_to_complex_shapes = line_to_complex_shapes
    end
    
    def points
      the_points = []
      basic_shapes.each_with_index do |shape, i|
        case shape
        when Point
          the_points << shape.to_a
        when Array
          the_points << shape.map {|n| BigDecimal(n.to_s)}
        when Line
          if i == 0
            shape.points.each do |point|
              the_points << point.to_a
            end
          else
            the_points << shape.points.last.to_a
          end
        when QuadraticBezierCurve
          shape.points.each do |point|
            the_points << point.to_a
          end
        when CubicBezierCurve
          shape.points.each do |point|
            the_points << point.to_a
          end
        end
      end
      if closed?
        first_basic_shape = basic_shapes.first
        closing_point = first_basic_shape.is_a?(Array) ? first_basic_shape : first_basic_shape.first_point
        the_points << closing_point
      end
      the_points
    end
    
    def points=(some_points)
      raise "Cannot assign points directly! Must set shapes instead and points are calculated from them automatically."
    end
    
    def drawing_types
      the_drawing_shapes = basic_shapes.each_with_index.flat_map do |shape, i|
        case shape
        when Point
          :move_to
        when Array
          :move_to
        when Line
          (i == 0) ? [:move_to, :line_to] : :line_to
        when QuadraticBezierCurve
          :quad_to
        when CubicBezierCurve
          :cubic_to
        end
      end
      the_drawing_shapes << :close if closed?
      the_drawing_shapes
    end
    
    def winding_rule=(value)
      raise "Invalid winding rule: #{value} (must be one of #{WINDING_RULES})" unless WINDING_RULES.include?(value.to_s.to_sym)
      @winding_rule = value
    end
    
    # Checks if path contains point (two-number Array or x, y args)
    # using the Nonzero-Rule (aka Winding Number Algorithm): https://en.wikipedia.org/wiki/Nonzero-rule
    # or using the Even-Odd Rule (aka Ray Casting Algorithm): https://en.wikipedia.org/wiki/Even%E2%80%93odd_rule
    #
    # @param x The X coordinate of the point to test.
    # @param y The Y coordinate of the point to test.
    #
    # @return true if the point lies within the bound of
    # the path or false if the point lies outside of the
    # path's bounds.
    def contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      
      if outline
        disconnected_shapes.any? {|shape| shape.contain?(x, y, outline: true, distance_tolerance: distance_tolerance) }
      else
        if (x * 0.0 + y * 0.0) == 0.0
          # N * 0.0 is 0.0 only if N is finite.
          # Here we know that both x and y are finite.
          return false if basic_shapes.count < 2
          mask = winding_rule == :wind_non_zero ? -1 : 1
          (point_crossings(x, y) & mask) != 0
        else
          # Either x or y was infinite or NaN.
          # A NaN always produces a negative response to any test
          # and Infinity values cannot be "inside" any path so
          # they should return false as well.
          false
        end
      end
    end
    
    # Calculates the number of times the given path
    # crosses the ray extending to the right from (x,y).
    # If the point lies on a part of the path,
    # then no crossings are counted for that intersection.
    # +1 is added for each crossing where the Y coordinate is increasing
    # -1 is added for each crossing where the Y coordinate is decreasing
    # The return value is the sum of all crossings for every segment in
    # the path.
    # The path must start with a PerfectShape::Point (initial location)
    # The caller must check for NaN values.
    # The caller may also reject infinite values as well.
    def point_crossings(x_or_point, y = nil)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      return 0 if basic_shapes.count == 0
      movx = movy = curx = cury = endx = endy = 0
      coords = points.flatten
      curx = movx = coords[0]
      cury = movy = coords[1]
      crossings = 0
      ci = 2
      1.upto(basic_shapes.count - 1).each do |i|
        case drawing_types[i]
        when :move_to
          if cury != movy
            line = PerfectShape::Line.new(points: [[curx, cury], [movx, movy]])
            crossings += line.point_crossings(x, y)
          end
          movx = curx = coords[ci]
          ci += 1
          movy = cury = coords[ci]
          ci += 1
        when :line_to
          endx = coords[ci]
          ci += 1
          endy = coords[ci]
          ci += 1
          line = PerfectShape::Line.new(points: [[curx, cury], [endx, endy]])
          crossings += line.point_crossings(x, y)
          curx = endx
          cury = endy
        when :quad_to
          quad_ctrlx = coords[ci]
          ci += 1
          quad_ctrly = coords[ci]
          ci += 1
          endx = coords[ci]
          ci += 1
          endy = coords[ci]
          ci += 1
          quad = PerfectShape::QuadraticBezierCurve.new(points: [[curx, cury], [quad_ctrlx, quad_ctrly], [endx, endy]])
          crossings += quad.point_crossings(x, y)
          curx = endx
          cury = endy
        when :cubic_to
          cubic_ctrl1x = coords[ci]
          ci += 1
          cubic_ctrl1y = coords[ci]
          ci += 1
          cubic_ctrl2x = coords[ci]
          ci += 1
          cubic_ctrl2y = coords[ci]
          ci += 1
          endx = coords[ci]
          ci += 1
          endy = coords[ci]
          ci += 1
          cubic = PerfectShape::CubicBezierCurve.new(points: [[curx, cury], [cubic_ctrl1x, cubic_ctrl1y], [cubic_ctrl2x, cubic_ctrl2y], [endx, endy]])
          crossings += cubic.point_crossings(x, y)
          curx = endx
          cury = endy
        when :close
          if cury != movy
            line = PerfectShape::Line.new(points: [[curx, cury], [movx, movy]])
            crossings += line.point_crossings(x, y)
          end
          curx = movx
          cury = movy
        end
      end
      if cury != movy
        line = PerfectShape::Line.new(points: [[curx, cury], [movx, movy]])
        crossings += line.point_crossings(x, y)
      end
      crossings
    end
    
    # Disconnected shapes have their start point filled in
    # so that each shape does not depend on the previous shape
    # to determine its start point.
    #
    # Also, if a point is followed by a non-point shape, it is removed
    # since it is augmented to the following shape as its start point.
    #
    # Lastly, if the path is closed, an extra shape is
    # added to represent the line connecting the last point to the first
    def disconnected_shapes
      # TODO it seems basic_shapes.first should always return a point, but there is a case with CompositeShape that results in a line (shape) not point returned
      first_point = basic_shapes.first.is_a?(Array) ? basic_shapes.first : basic_shapes.first.first_point
      initial_point = start_point = first_point.map {|n| BigDecimal(n.to_s)}
      final_point = nil
      the_disconnected_shapes = basic_shapes.drop(1).map do |shape|
        case shape
        when Point
          disconnected_shape = Point.new(*shape.to_a)
          start_point = shape.to_a
          final_point = disconnected_shape.to_a
          nil
        when Array
          disconnected_shape = Point.new(*shape.map {|n| BigDecimal(n.to_s)})
          start_point = shape.map {|n| BigDecimal(n.to_s)}
          final_point = disconnected_shape.to_a
          nil
        when Line
          disconnected_shape = Line.new(points: [start_point.to_a, shape.points.last])
          start_point = shape.points.last.to_a
          final_point = disconnected_shape.points.last.to_a
          disconnected_shape
        when QuadraticBezierCurve
          disconnected_shape = QuadraticBezierCurve.new(points: [start_point.to_a] + shape.points)
          start_point = shape.points.last.to_a
          final_point = disconnected_shape.points.last.to_a
          disconnected_shape
        when CubicBezierCurve
          disconnected_shape = CubicBezierCurve.new(points: [start_point.to_a] + shape.points)
          start_point = shape.points.last.to_a
          final_point = disconnected_shape.points.last.to_a
          disconnected_shape
        end
      end
      the_disconnected_shapes << Line.new(points: [final_point, initial_point]) if closed?
      the_disconnected_shapes.compact
    end
    
    def intersect?(rectangle)
      x = rectangle.x
      y = rectangle.y
      w = rectangle.width
      h = rectangle.height
      # [xy]+[wh] is NaN if any of those values are NaN,
      # or if adding the two together would produce NaN
      # by virtue of adding opposing Infinte values.
      # Since we need to add them below, their sum must
      # not be NaN.
      # We return false because NaN always produces a
      # negative response to tests
      return false if (x+w).nan? || (y+h).nan?
      return false if w <= 0 || h <= 0
      mask = winding_rule == :wind_non_zero ? -1 : 2
      crossings = rect_crossings(x, y, x+w, y+h)
      crossings == PerfectShape::Rectangle::RECT_INTERSECTS ||
        (crossings & mask) != 0
    end
    
    def rect_crossings(rxmin, rymin, rxmax, rymax)
      numTypes = drawing_types.count
      return 0 if numTypes == 0
      coords = points.flatten
      curx = cury = movx = movy = endx = endy = nil
      curx = movx = coords[0]
      cury = movy = coords[1]
      crossings = 0
      ci = 2
      i = 1
      
      while crossings != PerfectShape::Rectangle::RECT_INTERSECTS && i < numTypes
        case drawing_types[i]
        when :move_to
          if curx != movx || cury != movy
            line = PerfectShape::Line.new(points: [curx, cury, movx, movy])
            crossings = line.rect_crossings(rxmin, rymin, rxmax, rymax, crossings)
          end
          # Count should always be a multiple of 2 here.
          # assert((crossings & 1) != 0)
          movx = curx = coords[ci]
          ci += 1
          movy = cury = coords[ci]
          ci += 1
        when :line_to
          endx = coords[ci]
          ci += 1
          endy = coords[ci]
          ci += 1
          line = PerfectShape::Line.new(points: [curx, cury, endx, endy])
          crossings = line.rect_crossings(rxmin, rymin, rxmax, rymax, crossings)
          curx = endx
          cury = endy
        when :quad_to
          cx = coords[ci]
          ci += 1
          cy = coords[ci]
          ci += 1
          endx = coords[ci]
          ci += 1
          endy = coords[ci]
          ci += 1
          quadratic_bezier_curve = PerfectShape::QuadraticBezierCurve.new(points: [curx, cury, cx, cy, endx, endy])
          crossings = quadratic_bezier_curve.rect_crossings(rxmin, rymin, rxmax, rymax, 0, crossings)
          curx = endx
          cury = endy
        when :cubic_to
          c1x = coords[ci]
          ci += 1
          c1y = coords[ci]
          ci += 1
          c2x = coords[ci]
          ci += 1
          c2y = coords[ci]
          ci += 1
          endx = coords[ci]
          ci += 1
          endy = coords[ci]
          ci += 1
          cubic_bezier_curve = PerfectShape::CubicBezierCurve.new(points: [curx, cury, c1x, c1y, c2x, c2y, endx, endy])
          crossings = cubic_bezier_curve.rect_crossings(rxmin, rymin, rxmax, rymax, 0, crossings)
          curx = endx
          cury = endy
        when :close
          if curx != movx || cury != movy
            line = PerfectShape::Line.new(points: [curx, cury, movx, movy])
            crossings = line.rect_crossings(rxmin, rymin, rxmax, rymax, crossings)
          end
          curx = movx
          cury = movy
          # Count should always be a multiple of 2 here.
          # assert((crossings & 1) != 0)
        end
        i += 1
      end
      if crossings != PerfectShape::Rectangle::RECT_INTERSECTS &&
        (curx != movx || cury != movy)
        line = PerfectShape::Line.new(points: [curx, cury, movx, movy])
        crossings = line.rect_crossings(rxmin, rymin, rxmax, rymax, crossings)
      end
      # Count should always be a multiple of 2 here.
      # assert((crossings & 1) != 0)
      crossings
    end
    
    # Returns basic shapes (i.e. Point, Line, QuadraticBezierCurve, and CubicBezierCurve),
    # decomposed from complex shapes like Arc, Ellipse, and Circle by calling their `#to_path_shapes` method
    def basic_shapes
      the_shapes = []
      @shapes.each_with_index do |shape, i|
        if shape.respond_to?(:to_path_shapes)
          shape_basic_shapes = shape.to_path_shapes
          the_shapes << shape.first_point if i == 0
          if @line_to_complex_shapes
            first_basic_shape = shape_basic_shapes.shift
            new_first_basic_shape = PerfectShape::Line.new(points: [first_basic_shape.to_a])
            shape_basic_shapes.unshift(new_first_basic_shape)
          end
          the_shapes += shape_basic_shapes
        else
          the_shapes << shape
        end
      end
      the_shapes
    end
  end
end
