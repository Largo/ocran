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
require 'perfect_shape/multi_point'

module PerfectShape
  class CubicBezierCurve < Shape
    class << self
      # Calculates the number of times the cubic bézier curve from (x1,y1) to (x2,y2)
      # crosses the ray extending to the right from (x,y).
      # If the point lies on a part of the curve,
      # then no crossings are counted for that intersection.
      # the level parameter should be 0 at the top-level call and will count
      # up for each recursion level to prevent infinite recursion
      # +1 is added for each crossing where the Y coordinate is increasing
      # -1 is added for each crossing where the Y coordinate is decreasing
      def point_crossings(x1, y1, xc1, yc1, xc2, yc2, x2, y2, px, py, level = 0)
        return 0 if (py <  y1 && py <  yc1 && py <  yc2 && py <  y2)
        return 0 if (py >= y1 && py >= yc1 && py >= yc2 && py >= y2)
        # Note y1 could equal yc1...
        return 0 if (px >= x1 && px >= xc1 && px >= xc2 && px >= x2)
        if (px <  x1 && px <  xc1 && px <  xc2 && px <  x2)
          if (py >= y1)
            return 1 if (py < y2)
          else
            # py < y1
            return -1 if (py >= y2)
          end
          # py outside of y12 range, and/or y1==yc1
          return 0
        end
        # double precision only has 52 bits of mantissa
        return PerfectShape::Line.point_crossings(x1, y1, x2, y2, px, py) if (level > 52)
        xmid = BigDecimal((xc1 + xc2).to_s) / 2
        ymid = BigDecimal((yc1 + yc2).to_s) / 2
        xc1 = BigDecimal((x1 + xc1).to_s) / 2
        yc1 = BigDecimal((y1 + yc1).to_s) / 2
        xc2 = BigDecimal((xc2 + x2).to_s) / 2
        yc2 = BigDecimal((yc2 + y2).to_s) / 2
        xc1m = BigDecimal((xc1 + xmid).to_s) / 2
        yc1m = BigDecimal((yc1 + ymid).to_s) / 2
        xmc1 = BigDecimal((xmid + xc2).to_s) / 2
        ymc1 = BigDecimal((ymid + yc2).to_s) / 2
        xmid = BigDecimal((xc1m + xmc1).to_s) / 2
        ymid = BigDecimal((yc1m + ymc1).to_s) / 2
        # [xy]mid are NaN if any of [xy]c0m or [xy]mc1 are NaN
        # [xy]c0m or [xy]mc1 are NaN if any of [xy][c][01] are NaN
        # These values are also NaN if opposing infinities are added
        return 0 if (xmid.nan? || ymid.nan?)
        point_crossings(x1, y1, xc1, yc1, xc1m, yc1m, xmid, ymid, px, py, level+1) +
          point_crossings(xmid, ymid, xmc1, ymc1, xc2, yc2, x2, y2, px, py, level+1)
      end
    end
    
    include MultiPoint
    include Equalizer.new(:points)
    
    OUTLINE_MINIMUM_DISTANCE_THRESHOLD = BigDecimal('0.001')
    
    # Checks if cubic bézier curve contains point (two-number Array or x, y args)
    #
    # @param x The X coordinate of the point to test.
    # @param y The Y coordinate of the point to test.
    #
    # @return true if the point lies within the bound of
    # the cubic bézier curve, false if the point lies outside of the
    # cubic bézier curve's bounds.
    def contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      
      if outline
        distance_tolerance = BigDecimal(distance_tolerance.to_s)
        minimum_distance_threshold = OUTLINE_MINIMUM_DISTANCE_THRESHOLD + distance_tolerance
        point_distance(x, y, minimum_distance_threshold: minimum_distance_threshold) < minimum_distance_threshold
      else
        # Either x or y was infinite or NaN.
        # A NaN always produces a negative response to any test
        # and Infinity values cannot be "inside" any path so
        # they should return false as well.
        return false if (!(x * 0.0 + y * 0.0 == 0.0))
        # We count the "Y" crossings to determine if the point is
        # inside the curve bounded by its closing line.
        x1 = points[0][0]
        y1 = points[0][1]
        x2 = points[3][0]
        y2 = points[3][1]
        line = PerfectShape::Line.new(points: [[x1, y1], [x2, y2]])
        crossings = line.point_crossings(x, y) + point_crossings(x, y)
        (crossings & 1) == 1
      end
    end
    
    # Calculates the number of times the cubic bézier curve
    # crosses the ray extending to the right from (x,y).
    # If the point lies on a part of the curve,
    # then no crossings are counted for that intersection.
    # the level parameter should be 0 at the top-level call and will count
    # up for each recursion level to prevent infinite recursion
    # +1 is added for each crossing where the Y coordinate is increasing
    # -1 is added for each crossing where the Y coordinate is decreasing
    def point_crossings(x_or_point, y = nil, level = 0)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      CubicBezierCurve.point_crossings(points[0][0], points[0][1], points[1][0], points[1][1], points[2][0], points[2][1], points[3][0], points[3][1], x, y, level)
    end
    
    # The center point on the outline of the curve
    def curve_center_point
      subdivisions.last.points[0]
    end
    
    # The center point x on the outline of the curve
    def curve_center_x
      subdivisions.last.points[0][0]
    end
    
    # The center point y on the outline of the curve
    def curve_center_y
      subdivisions.last.points[0][1]
    end
    
    # Subdivides CubicBezierCurve exactly at its curve center
    # returning 2 CubicBezierCurve's as a two-element Array by default
    #
    # Optional `level` parameter specifies the level of recursions to
    # perform to get more subdivisions. The number of resulting
    # subdivisions is 2 to the power of `level` (e.g. 2 subdivisions
    # for level=1, 4 subdivisions for level=2, and 8 subdivisions for level=3)
    def subdivisions(level = 1)
      level -= 1 # consume 1 level
      
      x1 = points[0][0]
      y1 = points[0][1]
      ctrlx1 = points[1][0]
      ctrly1 = points[1][1]
      ctrlx2 = points[2][0]
      ctrly2 = points[2][1]
      x2 = points[3][0]
      y2 = points[3][1]
      centerx = BigDecimal((ctrlx1 + ctrlx2).to_s) / 2
      centery = BigDecimal((ctrly1 + ctrly2).to_s) / 2
      ctrlx1 = BigDecimal((x1 + ctrlx1).to_s) / 2
      ctrly1 = BigDecimal((y1 + ctrly1).to_s) / 2
      ctrlx2 = BigDecimal((x2 + ctrlx2).to_s) / 2
      ctrly2 = BigDecimal((y2 + ctrly2).to_s) / 2
      ctrlx12 = BigDecimal((ctrlx1 + centerx).to_s) / 2
      ctrly12 = BigDecimal((ctrly1 + centery).to_s) / 2
      ctrlx21 = BigDecimal((ctrlx2 + centerx).to_s) / 2
      ctrly21 = BigDecimal((ctrly2 + centery).to_s) / 2
      centerx = BigDecimal((ctrlx12 + ctrlx21).to_s) / 2
      centery = BigDecimal((ctrly12 + ctrly21).to_s) / 2
      
      first_curve = CubicBezierCurve.new(points: [x1, y1, ctrlx1, ctrly1, ctrlx12, ctrly12, centerx, centery])
      second_curve = CubicBezierCurve.new(points: [centerx, centery, ctrlx21, ctrly21, ctrlx2, ctrly2, x2, y2])
      default_subdivisions = [first_curve, second_curve]
      
      if level == 0
        default_subdivisions
      else
        default_subdivisions.map { |curve| curve.subdivisions(level) }.flatten
      end
    end
    
    def point_distance(x_or_point, y = nil, minimum_distance_threshold: OUTLINE_MINIMUM_DISTANCE_THRESHOLD)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      
      point = Point.new(x, y)
      current_curve = self
      minimum_distance = point.point_distance(curve_center_point)
      last_minimum_distance = minimum_distance + 1 # start bigger to ensure going through loop once at least
      while minimum_distance >= minimum_distance_threshold && minimum_distance < last_minimum_distance
        curve1, curve2 = current_curve.subdivisions
        curve1_center_point = curve1.curve_center_point
        distance1 = point.point_distance(curve1_center_point)
        curve2_center_point = curve2.curve_center_point
        distance2 = point.point_distance(curve2_center_point)
        last_minimum_distance = minimum_distance
        if distance1 < distance2
          minimum_distance = distance1
          current_curve = curve1
        else
          minimum_distance = distance2
          current_curve = curve2
        end
      end
      if minimum_distance < minimum_distance_threshold
        minimum_distance
      else
        last_minimum_distance
      end
    end
    
    def intersect?(rectangle)
      w = rectangle.width
      h = rectangle.height
      
      # Trivially reject non-existant rectangles
      return false if w <= 0 || h <= 0

      num_crossings = rectangle_crossings(rectangle)
      # the intended return value is
      # num_crossings != 0 || num_crossings == PerfectShape::Rectangle::RECT_INTERSECTS
      # but if (num_crossings != 0) num_crossings == INTERSECTS won't matter
      # and if !(num_crossings != 0) then num_crossings == 0, so
      # num_crossings != RECT_INTERSECT
      num_crossings != 0
    end
    
    def rectangle_crossings(rectangle)
      x = rectangle.x
      y = rectangle.y
      w = rectangle.width
      h = rectangle.height
      x1 = points[0][0]
      y1 = points[0][1]
      x2 = points[3][0]
      y2 = points[3][1]
    
      crossings = 0
      if !(x1 == x2 && y1 == y2)
        line = PerfectShape::Line.new(points: [[x1, y1], [x2, y2]])
        crossings = line.rect_crossings(x, y, x+w, y+h, crossings)
        return crossings if crossings == PerfectShape::Rectangle::RECT_INTERSECTS
      end
      # we call this with the curve's direction reversed, because we wanted
      # to call rectCrossingsForLine first, because it's cheaper.
      rect_crossings(x, y, x+w, y+h, 0, crossings)
    end
    
    # Accumulate the number of times the cubic crosses the shadow
    # extending to the right of the rectangle.  See the comment
    # for the RECT_INTERSECTS constant for more complete details.
    #
    # crossings arg is the initial crossings value to add to (useful
    # in cases where you want to accumulate crossings from multiple
    # shapes)
    def rect_crossings(rxmin, rymin, rxmax, rymax, level, crossings = 0)
      x0 = points[0][0]
      y0 = points[0][1]
      xc0 = points[1][0]
      yc0 = points[1][1]
      xc1 = points[2][0]
      yc1 = points[2][1]
      x1 = points[3][0]
      y1 = points[3][1]
      
      return crossings if y0 >= rymax && yc0 >= rymax && yc1 >= rymax && y1 >= rymax
      return crossings if y0 <= rymin && yc0 <= rymin && yc1 <= rymin && y1 <= rymin
      return crossings if x0 <= rxmin && xc0 <= rxmin && xc1 <= rxmin && x1 <= rxmin
      if x0 >= rxmax && xc0 >= rxmax && xc1 >= rxmax && x1 >= rxmax
        # Cubic is entirely to the right of the rect
        # and the vertical range of the 4 Y coordinates of the cubic
        # overlaps the vertical range of the rect by a non-empty amount
        # We now judge the crossings solely based on the line segment
        # connecting the endpoints of the cubic.
        # Note that we may have 0, 1, or 2 crossings as the control
        # points may be causing the Y range intersection while the
        # two endpoints are entirely above or below.
        if y0 < y1
          # y-increasing line segment...
          crossings += 1 if (y0 <= rymin && y1 >  rymin)
          crossings += 1 if (y0 <  rymax && y1 >= rymax)
        elsif y1 < y0
          # y-decreasing line segment...
          crossings -= 1 if (y1 <= rymin && y0 >  rymin)
          crossings -= 1 if (y1 <  rymax && y0 >= rymax)
        end
        return crossings
      end
      # The intersection of ranges is more complicated
      # First do trivial INTERSECTS rejection of the cases
      # where one of the endpoints is inside the rectangle.
      return PerfectShape::Rectangle::RECT_INTERSECTS if ((x0 > rxmin && x0 < rxmax && y0 > rymin && y0 < rymax) ||
        (x1 > rxmin && x1 < rxmax && y1 > rymin && y1 < rymax))
          
      # Otherwise, subdivide and look for one of the cases above.
      # double precision only has 52 bits of mantissa
      return PerfectShape::Line.new(points: [[x0, y0], [x1, y1]]).rect_crossings(rxmin, rymin, rxmax, rymax, crossings) if (level > 52)
      xmid = BigDecimal((xc0 + xc1).to_s) / 2
      ymid = BigDecimal((yc0 + yc1).to_s) / 2
      xc0 = BigDecimal((x0 + xc0).to_s) / 2
      yc0 = BigDecimal((y0 + yc0).to_s) / 2
      xc1 = BigDecimal((xc1 + x1).to_s) / 2
      yc1 = BigDecimal((yc1 + y1).to_s) / 2
      xc0m = BigDecimal((xc0 + xmid).to_s) / 2
      yc0m = BigDecimal((yc0 + ymid).to_s) / 2
      xmc1 = BigDecimal((xmid + xc1).to_s) / 2
      ymc1 = BigDecimal((ymid + yc1).to_s) / 2
      xmid = BigDecimal((xc0m + xmc1).to_s) / 2
      ymid = BigDecimal((yc0m + ymc1).to_s) / 2
      # [xy]mid are NaN if any of [xy]c0m or [xy]mc1 are NaN
      # [xy]c0m or [xy]mc1 are NaN if any of [xy][c][01] are NaN
      # These values are also NaN if opposing infinities are added
      return 0 if xmid.nan? || ymid.nan?
      cubic1 = CubicBezierCurve.new(points: [[x0, y0], [xc0, yc0], [xc0m, yc0m], [xmid, ymid]])
      crossings = cubic1.rect_crossings(rxmin, rymin, rxmax, rymax, level + 1, crossings)
      if crossings != PerfectShape::Rectangle::RECT_INTERSECTS
        cubic2 = CubicBezierCurve.new(points: [[xmid, ymid], [xmc1, ymc1], [xc1, yc1], [x1, y1]])
        crossings = cubic2.rect_crossings(rxmin, rymin, rxmax, rymax, level + 1, crossings)
      end
      crossings
    end
  end
end
