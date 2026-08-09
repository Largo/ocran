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
  class Line < Shape
    class << self
      # Returns an indicator of where the specified point (px,py) lies with respect to the line segment from
      # (x1,y1) to (x2,y2).
      #
      # The return value can be either 1, -1, or 0 and indicates in which direction the specified line must pivot around its first end point, (x1,y1), in order to point at the specified point (px,py).
      # A return value of 1 indicates that the line segment must turn in the direction that takes the positive X axis towards the negative Y axis. In the default coordinate system used by Java 2D, this direction is counterclockwise.
      #
      # A return value of -1 indicates that the line segment must turn in the direction that takes the positive X axis towards the positive Y axis. In the default coordinate system, this direction is clockwise.
      #
      # A return value of 0 indicates that the point lies exactly on the line segment. Note that an indicator value of 0 is rare and not useful for determining collinearity because of floating point rounding issues.
      #
      # If the point is colinear with the line segment, but not between the end points, then the value will be -1 if the point lies “beyond (x1,y1)” or 1 if the point lies “beyond (x2,y2)”.
      #
      # @param x1 the X coordinate of the start point of the
      #           specified line segment
      # @param y1 the Y coordinate of the start point of the
      #           specified line segment
      # @param x2 the X coordinate of the end point of the
      #           specified line segment
      # @param y2 the Y coordinate of the end point of the
      #           specified line segment
      # @param px the X coordinate of the specified point to be
      #           compared with the specified line segment
      # @param py the Y coordinate of the specified point to be
      #           compared with the specified line segment
      # @return an integer that indicates the position of the third specified
      #                  coordinates with respect to the line segment formed
      #                  by the first two specified coordinates.
      def relative_counterclockwise(x1, y1, x2, y2, px, py)
        x2 -= x1
        y2 -= y1
        px -= x1
        py -= y1
        ccw = px * y2 - py * x2
        if ccw == 0.0
          # The point is colinear, classify based on which side of
          # the segment the point falls on.  We can calculate a
          # relative value using the projection of px,py onto the
          # segment - a negative value indicates the point projects
          # outside of the segment in the direction of the particular
          # endpoint used as the origin for the projection.
          ccw = px * x2 + py * y2
          if ccw > 0.0
            # Reverse the projection to be relative to the original x2,y2
            # x2 and y2 are simply negated.
            # px and py need to have (x2 - x1) or (y2 - y1) subtracted
            #    from them (based on the original values)
            # Since we really want to get a positive answer when the
            #    point is "beyond (x2,y2)", then we want to calculate
            #    the inverse anyway - thus we leave x2 & y2 negated.
            px -= x2
            py -= y2
            ccw = px * x2 + py * y2
            ccw = 0.0 if ccw < 0.0
          end
        end
        (ccw < 0.0) ? -1 : ((ccw > 0.0) ? 1 : 0)
      end
      
      # Returns the square of the distance from a point to a line segment.
      # The distance measured is the distance between the specified
      # point and the closest point between the specified end points.
      # If the specified point intersects the line segment in between the
      # end points, this method returns 0.0.
      #
      # @param x1 the X coordinate of the start point of the
      #           specified line segment
      # @param y1 the Y coordinate of the start point of the
      #           specified line segment
      # @param x2 the X coordinate of the end point of the
      #           specified line segment
      # @param y2 the Y coordinate of the end point of the
      #           specified line segment
      # @param px the X coordinate of the specified point being
      #           measured against the specified line segment
      # @param py the Y coordinate of the specified point being
      #           measured against the specified line segment
      # @return a double value that is the square of the distance from the
      #                  specified point to the specified line segment.
      def point_distance_square(x1, y1,
                                       x2, y2,
                                       px, py)
        x1 = BigDecimal(x1.to_s)
        y1 = BigDecimal(y1.to_s)
        x2 = BigDecimal(x2.to_s)
        y2 = BigDecimal(y2.to_s)
        px = BigDecimal(px.to_s)
        py = BigDecimal(py.to_s)
        # Adjust vectors relative to x1,y1
        # x2,y2 becomes relative vector from x1,y1 to end of segment
        x2 -= x1
        y2 -= y1
        # px,py becomes relative vector from x1,y1 to test point
        px -= x1
        py -= y1
        dot_product = px * x2 + py * y2
        if dot_product <= 0.0
          # px,py is on the side of x1,y1 away from x2,y2
          # distance to segment is length of px,py vector
          # "length of its (clipped) projection" is now 0.0
          projected_length_square = BigDecimal('0.0')
        else
          # switch to backwards vectors relative to x2,y2
          # x2,y2 are already the negative of x1,y1=>x2,y2
          # to get px,py to be the negative of px,py=>x2,y2
          # the dot product of two negated vectors is the same
          # as the dot product of the two normal vectors
          px = x2 - px
          py = y2 - py
          dot_product = px * x2 + py * y2
          if dot_product <= 0.0
            # px,py is on the side of x2,y2 away from x1,y1
            # distance to segment is length of (backwards) px,py vector
            # "length of its (clipped) projection" is now 0.0
            projected_length_square = BigDecimal('0.0')
          else
            # px,py is between x1,y1 and x2,y2
            # dot_product is the length of the px,py vector
            # projected on the x2,y2=>x1,y1 vector times the
            # length of the x2,y2=>x1,y1 vector
            projected_length_square = dot_product * dot_product / (x2 * x2 + y2 * y2)
          end
        end
        # Distance to line is now the length of the relative point
        # vector minus the length of its projection onto the line
        # (which is zero if the projection falls outside the range
        #  of the line segment).
        length_square = px * px + py * py - projected_length_square
        length_square = BigDecimal('0.0') if length_square < 0
        length_square
      end
      
      # Returns the distance from a point to a line segment.
      # The distance measured is the distance between the specified
      # point and the closest point between the specified end points.
      # If the specified point intersects the line segment in between the
      # end points, this method returns 0.0.
      #
      # @param x1 the X coordinate of the start point of the
      #           specified line segment
      # @param y1 the Y coordinate of the start point of the
      #           specified line segment
      # @param x2 the X coordinate of the end point of the
      #           specified line segment
      # @param y2 the Y coordinate of the end point of the
      #           specified line segment
      # @param px the X coordinate of the specified point being
      #           measured against the specified line segment
      # @param py the Y coordinate of the specified point being
      #           measured against the specified line segment
      # @return a double value that is the distance from the specified point
      #                          to the specified line segment.
      def point_distance(x1, y1,
                                 x2, y2,
                                 px, py)
        BigDecimal(::Math.sqrt(point_distance_square(x1, y1, x2, y2, px, py)).to_s)
      end
      
      # Calculates the number of times the line from (x1,y1) to (x2,y2)
      # crosses the ray extending to the right from (px,py).
      # If the point lies on the line, then no crossings are recorded.
      # +1 is returned for a crossing where the Y coordinate is increasing
      # -1 is returned for a crossing where the Y coordinate is decreasing
      def point_crossings(x1, y1, x2, y2, px, py)
        return 0 if (py <  y1 && py <  y2)
        return 0 if (py >= y1 && py >= y2)
        # assert(y1 != y2)
        return 0 if (px >= x1 && px >= x2)
        return ((y1 < y2) ? 1 : -1) if (px <  x1 && px <  x2)
        xintercept = x1 + (py - y1) * (x2 - x1) / (y2 - y1)
        return 0 if (px >= xintercept)
        (y1 < y2) ? 1 : -1
      end
    end
    
    include MultiPoint
    include Equalizer.new(:points)
    
    # Checks if line contains point (two-number Array or x, y args), with distance tolerance (0 by default)
    #
    # @param x The X coordinate of the point to test.
    # @param y The Y coordinate of the point to test.
    # @param distance_tolerance The distance from line to tolerate (0 by default)
    #
    # @return true if the point lies within the bound of
    # the line, false if the point lies outside of the
    # line's bounds.
    def contain?(x_or_point, y = nil, outline: true, distance_tolerance: 0)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      distance_tolerance = BigDecimal(distance_tolerance.to_s)
      point_distance(x, y) <= distance_tolerance
    end
    
    def point_distance(x_or_point, y = nil)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      Line.point_distance(points[0][0], points[0][1], points[1][0], points[1][1], x, y)
    end
    
    def relative_counterclockwise(x_or_point, y = nil)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      Line.relative_counterclockwise(points[0][0], points[0][1], points[1][0], points[1][1], x, y)
    end
    
    # Calculates the number of times the line
    # crosses the ray extending to the right from (px,py).
    # If the point lies on the line, then no crossings are recorded.
    # +1 is returned for a crossing where the Y coordinate is increasing
    # -1 is returned for a crossing where the Y coordinate is decreasing
    def point_crossings(x_or_point, y = nil)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      Line.point_crossings(points[0][0], points[0][1], points[1][0], points[1][1], x, y)
    end
    
    # Accumulate the number of times the line crosses the shadow
    # extending to the right of the rectangle.  See the comment
    # for the PerfectShape::Rectangle::RECT_INTERSECTS constant for more complete details.
    #
    # crossings arg is the initial crossings value to add to (useful
    # in cases where you want to accumulate crossings from multiple
    # shapes)
    def rect_crossings(rxmin, rymin, rxmax, rymax, crossings = 0)
      x0 = points[0][0]
      y0 = points[0][1]
      x1 = points[1][0]
      y1 = points[1][1]
      return crossings if y0 >= rymax && y1 >= rymax
      return crossings if y0 <= rymin && y1 <= rymin
      return crossings if x0 <= rxmin && x1 <= rxmin
      if x0 >= rxmax && x1 >= rxmax
        # Line is entirely to the right of the rect
        # and the vertical ranges of the two overlap by a non-empty amount
        # Thus, this line segment is partially in the "right-shadow"
        # Path may have done a complete crossing
        # Or path may have entered or exited the right-shadow
        if y0 < y1
            # y-increasing line segment...
            # We know that y0 < rymax and y1 > rymin
            crossings += 1 if (y0 <= rymin)
            crossings += 1 if (y1 >= rymax)
        elsif y1 < y0
            # y-decreasing line segment...
            # We know that y1 < rymax and y0 > rymin
            crossings -= 1 if (y1 <= rymin)
            crossings -= 1 if (y0 >= rymax)
        end
        return crossings
      end
      # Remaining case:
      # Both x and y ranges overlap by a non-empty amount
      # First do trivial INTERSECTS rejection of the cases
      # where one of the endpoints is inside the rectangle.
      return PerfectShape::Rectangle::RECT_INTERSECTS if ((x0 > rxmin && x0 < rxmax && y0 > rymin && y0 < rymax) ||
        (x1 > rxmin && x1 < rxmax && y1 > rymin && y1 < rymax))
      # Otherwise calculate the y intercepts and see where
      # they fall with respect to the rectangle
      xi0 = x0
      if y0 < rymin
        xi0 += ((rymin - y0) * (x1 - x0) / (y1 - y0))
      elsif y0 > rymax
        xi0 += ((rymax - y0) * (x1 - x0) / (y1 - y0))
      end
      xi1 = x1
      if y1 < rymin
        xi1 += ((rymin - y1) * (x0 - x1) / (y0 - y1))
      elsif y1 > rymax
        xi1 += ((rymax - y1) * (x0 - x1) / (y0 - y1))
      end
      return crossings if xi0 <= rxmin && xi1 <= rxmin
      if xi0 >= rxmax && xi1 >= rxmax
        if y0 < y1
          # y-increasing line segment...
          # We know that y0 < rymax and y1 > rymin
          crossings += 1 if (y0 <= rymin)
          crossings += 1 if (y1 >= rymax)
        elsif y1 < y0
          # y-decreasing line segment...
          # We know that y1 < rymax and y0 > rymin
          crossings -= 1 if (y1 <= rymin)
          crossings -= 1 if (y0 >= rymax)
        end
        return crossings
      end
      PerfectShape::Rectangle::RECT_INTERSECTS
    end
    
    def intersect?(rectangle)
      require 'perfect_shape/rectangle'
      x1 = points[0][0]
      y1 = points[0][1]
      x2 = points[1][0]
      y2 = points[1][1]
      out1 = out2 = nil
      return true if (out2 = rectangle.out_state(x2, y2)) == 0
      while (out1 = rectangle.out_state(x1, y1)) != 0
        return false if (out1 & out2) != 0
        if (out1 & (Rectangle::OUT_LEFT | Rectangle::OUT_RIGHT)) != 0
          x = rectangle.x
          x += rectangle.width if (out1 & Rectangle::OUT_RIGHT) != 0
          y1 = y1 + (x - x1) * (y2 - y1) / (x2 - x1)
          x1 = x
        else
          y = rectangle.y
          y += rectangle.height if (out1 & Rectangle::OUT_BOTTOM) != 0
          x1 = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
          y1 = y
        end
      end
      true
    end
  end
end
