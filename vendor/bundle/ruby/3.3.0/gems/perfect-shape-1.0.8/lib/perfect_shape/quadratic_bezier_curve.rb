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
  class QuadraticBezierCurve < Shape
    class << self
      # Calculates the number of times the quadratic bézier curve from (x1,y1) to (x2,y2)
      # crosses the ray extending to the right from (x,y).
      # If the point lies on a part of the curve,
      # then no crossings are counted for that intersection.
      # the level parameter should be 0 at the top-level call and will count
      # up for each recursion level to prevent infinite recursion
      # +1 is added for each crossing where the Y coordinate is increasing
      # -1 is added for each crossing where the Y coordinate is decreasing
      def point_crossings(x1, y1, xc, yc, x2, y2, px, py, level = 0)
        return 0 if (py <  y1 && py <  yc && py <  y2)
        return 0 if (py >= y1 && py >= yc && py >= y2)
        # Note y1 could equal y2...
        return 0 if (px >= x1 && px >= xc && px >= x2)
        if (px <  x1 && px <  xc && px <  x2)
          if (py >= y1)
            return 1 if (py < y2)
          else
            # py < y1
            return -1 if (py >= y2)
          end
          # py outside of y11 range, and/or y1==y2
          return 0
        end
        # double precision only has 52 bits of mantissa
        return PerfectShape::Line.point_crossings(x1, y1, x2, y2, px, py) if (level > 52)
        x1c = BigDecimal((x1 + xc).to_s) / 2
        y1c = BigDecimal((y1 + yc).to_s) / 2
        xc1 = BigDecimal((xc + x2).to_s) / 2
        yc1 = BigDecimal((yc + y2).to_s) / 2
        xc = BigDecimal((x1c + xc1).to_s) / 2
        yc = BigDecimal((y1c + yc1).to_s) / 2
        # [xy]c are NaN if any of [xy]0c or [xy]c1 are NaN
        # [xy]0c or [xy]c1 are NaN if any of [xy][0c1] are NaN
        # These values are also NaN if opposing infinities are added
        return 0 if (xc.nan? || yc.nan?)
        point_crossings(x1, y1, x1c, y1c, xc, yc, px, py, level+1) +
          point_crossings(xc, yc, xc1, yc1, x2, y2, px, py, level+1)
      end
      
      # Determine where coord lies with respect to the range from
      # low to high.  It is assumed that low < high.  The return
      # value is one of the 5 values BELOW, LOWEDGE, INSIDE, HIGHEDGE,
      # or ABOVE.
      def tag(coord, low, high)
        return (coord < low ? BELOW : LOWEDGE) if coord <= low
        return (coord > high ? ABOVE : HIGHEDGE) if coord >= high
        INSIDE
      end
      
      # Fill an array with the coefficients of the parametric equation
      # in t, ready for solving against val with solve_quadratic.
      # We currently have:
      #     val = Py(t) = C1*(1-t)^2 + 2*CP*t*(1-t) + C2*t^2
      #                 = C1 - 2*C1*t + C1*t^2 + 2*CP*t - 2*CP*t^2 + C2*t^2
      #                 = C1 + (2*CP - 2*C1)*t + (C1 - 2*CP + C2)*t^2
      #               0 = (C1 - val) + (2*CP - 2*C1)*t + (C1 - 2*CP + C2)*t^2
      #               0 = C + Bt + At^2
      #     C = C1 - val
      #     B = 2*CP - 2*C1
      #     A = C1 - 2*CP + C2
      def eqn(val, c1, cp, c2)
        [
          c1 - val,
          cp + cp - c1 - c1,
          c1 - cp - cp + c2,
        ]
      end
      
      # Solves the quadratic whose coefficients are in the eqn
      # array and places the non-complex roots into the res
      # array, returning the number of roots.
      # The quadratic solved is represented by the equation:
      # <pre>
      #     eqn = {C, B, A}
      #     ax^2 + bx + c = 0
      # </pre>
      # A return value of -1 is used to distinguish a constant
      # equation, which might be always 0 or never 0, from an equation that
      # has no zeroes.
      # @param eqn the specified array of coefficients to use to solve
      #        the quadratic equation
      # @param res the array that contains the non-complex roots
      #        resulting from the solution of the quadratic equation
      # @return the number of roots, or -1 if the equation is
      #  a constant.
      def solve_quadratic(eqn, res)
        a = eqn[2]
        b = eqn[1]
        c = eqn[0]
        roots = -1
        if a == 0.0
          #  The quadratic parabola has degenerated to a line.
          #  The line has degenerated to a constant.
          return -1 if b == 0.0
          res[roots += 1] = -c / b
        else
          #  From Numerical Recipes, 5.6, Quadratic and Cubic Equations
          d = b * b - 4.0 * a * c
          #  If d < 0.0, then there are no roots
          return 0 if d < 0.0
          d = BigDecimal(Math.sqrt(d).to_a)
          #  For accuracy, calculate one root using:
          #      (-b +/- d) / 2a
          #  and the other using:
          #      2c / (-b +/- d)
          #  Choose the sign of the +/- so that b+d gets larger in magnitude
          d = -d if b < 0.0
          q = (b + d) / -2.0
          #  We already tested a for being 0 above
          res[roots += 1] = q / a
          res[roots += 1] = c / q if q != 0.0
        end
        roots
      end
      
      # Evaluate the t values in the first num slots of the vals[] array
      # and place the evaluated values back into the same array.  Only
      # evaluate t values that are within the range <, >, including
      # the 0 and 1 ends of the range iff the include0 or include1
      # booleans are true.  If an "inflection" equation is handed in,
      # then any points which represent a point of inflection for that
      # quadratic equation are also ignored.
      def eval_quadratic(vals, num,
                                   include0,
                                   include1,
                                   inflect,
                                   c1, ctrl, c2)
        j = -1
        i = 0
        while i < num
          t = vals[i]
          
          if ((include0 ? t >= 0 : t > 0) &&
              (include1 ? t <= 1 : t < 1) &&
              (inflect.nil? ||
               inflect[1] + 2*inflect[2]*t != 0))
            u = 1 - t
            vals[j+=1] = c1*u*u + 2*ctrl*t*u + c2*t*t
          end
          i+=1
        end
        j
      end
    end
    
    include MultiPoint
    include Equalizer.new(:points)
    
    BELOW = -2
    LOWEDGE = -1
    INSIDE = 0
    HIGHEDGE = 1
    ABOVE = 2
    
    OUTLINE_MINIMUM_DISTANCE_THRESHOLD = BigDecimal('0.001')
    
    # Checks if quadratic bézier curve contains point (two-number Array or x, y args)
    #
    # @param x The X coordinate of the point to test.
    # @param y The Y coordinate of the point to test.
    #
    # @return true if the point lies within the bound of
    # the quadratic bézier curve, false if the point lies outside of the
    # quadratic bézier curve's bounds.
    def contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y

      x1 = points[0][0]
      y1 = points[0][1]
      xc = points[1][0]
      yc = points[1][1]
      x2 = points[2][0]
      y2 = points[2][1]
      
      if outline
        distance_tolerance = BigDecimal(distance_tolerance.to_s)
        minimum_distance_threshold = OUTLINE_MINIMUM_DISTANCE_THRESHOLD + distance_tolerance
        point_distance(x, y, minimum_distance_threshold: minimum_distance_threshold) < minimum_distance_threshold
      else
        # We have a convex shape bounded by quad curve Pc(t)
        # and ine Pl(t).
        #
        #     P1 = (x1, y1) - start point of curve
        #     P2 = (x2, y2) - end point of curve
        #     Pc = (xc, yc) - control point
        #
        #     Pq(t) = P1*(1 - t)^2 + 2*Pc*t*(1 - t) + P2*t^2 =
        #           = (P1 - 2*Pc + P2)*t^2 + 2*(Pc - P1)*t + P1
        #     Pl(t) = P1*(1 - t) + P2*t
        #     t = [0:1]
        #
        #     P = (x, y) - point of interest
        #
        # Let's look at second derivative of quad curve equation:
        #
        #     Pq''(t) = 2 * (P1 - 2 * Pc + P2) = Pq''
        #     It's constant vector.
        #
        # Let's draw a line through P to be parallel to this
        # vector and find the intersection of the quad curve
        # and the line.
        #
        # Pq(t) is point of intersection if system of equations
        # below has the solution.
        #
        #     L(s) = P + Pq''*s == Pq(t)
        #     Pq''*s + (P - Pq(t)) == 0
        #
        #     | xq''*s + (x - xq(t)) == 0
        #     | yq''*s + (y - yq(t)) == 0
        #
        # This system has the solution if rank of its matrix equals to 1.
        # That is, determinant of the matrix should be zero.
        #
        #     (y - yq(t))*xq'' == (x - xq(t))*yq''
        #
        # Let's solve this equation with 't' variable.
        # Also let kx = x1 - 2*xc + x2
        #          ky = y1 - 2*yc + y2
        #
        #     t0q = (1/2)*((x - x1)*ky - (y - y1)*kx) /
        #                 ((xc - x1)*ky - (yc - y1)*kx)
        #
        # Let's do the same for our line Pl(t):
        #
        #     t0l = ((x - x1)*ky - (y - y1)*kx) /
        #           ((x2 - x1)*ky - (y2 - y1)*kx)
        #
        # It's easy to check that t0q == t0l. This fact means
        # we can compute t0 only one time.
        #
        # In case t0 < 0 or t0 > 1, we have an intersections outside
        # of shape bounds. So, P is definitely out of shape.
        #
        # In case t0 is inside [0:1], we should calculate Pq(t0)
        # and Pl(t0). We have three points for now, and all of them
        # lie on one line. So, we just need to detect, is our point
        # of interest between points of intersections or not.
        #
        # If the denominator in the t0q and t0l equations is
        # zero, then the points must be collinear and so the
        # curve is degenerate and encloses no area.  Thus the
        # result is false.
        kx = x1 - 2 * xc + x2
        ky = y1 - 2 * yc + y2
        dx = x - x1
        dy = y - y1
        dxl = x2 - x1
        dyl = y2 - y1
  
        t0 = (dx * ky - dy * kx) / (dxl * ky - dyl * kx)
        return false if (t0 < 0 || t0 > 1 || t0 != t0)
  
        xb = kx * t0 * t0 + 2 * (xc - x1) * t0 + x1
        yb = ky * t0 * t0 + 2 * (yc - y1) * t0 + y1
        xl = dxl * t0 + x1
        yl = dyl * t0 + y1
  
        (x >= xb && x < xl) ||
          (x >= xl && x < xb) ||
          (y >= yb && y < yl) ||
          (y >= yl && y < yb)
      end
    end
    
    # Calculates the number of times the quad
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
      QuadraticBezierCurve.point_crossings(points[0][0], points[0][1], points[1][0], points[1][1], points[2][0], points[2][1], x, y, level)
    end
    
    # The center point on the outline of the curve
    # in Array format as pair of (x, y) coordinates
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
    
    # Subdivides QuadraticBezierCurve exactly at its curve center
    # returning 2 QuadraticBezierCurve's as a two-element Array by default
    #
    # Optional `level` parameter specifies the level of recursions to
    # perform to get more subdivisions. The number of resulting
    # subdivisions is 2 to the power of `level` (e.g. 2 subdivisions
    # for level=1, 4 subdivisions for level=2, and 8 subdivisions for level=3)
    def subdivisions(level = 1)
      level -= 1 # consume 1 level
      
      x1 = points[0][0]
      y1 = points[0][1]
      ctrlx = points[1][0]
      ctrly = points[1][1]
      x2 = points[2][0]
      y2 = points[2][1]
      ctrlx1 = BigDecimal((x1 + ctrlx).to_s) / 2
      ctrly1 = BigDecimal((y1 + ctrly).to_s) / 2
      ctrlx2 = BigDecimal((x2 + ctrlx).to_s) / 2
      ctrly2 = BigDecimal((y2 + ctrly).to_s) / 2
      centerx = BigDecimal((ctrlx1 + ctrlx2).to_s) / 2
      centery = BigDecimal((ctrly1 + ctrly2).to_s) / 2
      
      default_subdivisions = [
        QuadraticBezierCurve.new(points: [x1, y1, ctrlx1, ctrly1, centerx, centery]),
        QuadraticBezierCurve.new(points: [centerx, centery, ctrlx2, ctrly2, x2, y2])
      ]
      
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
        distance1 = point.point_distance(curve1.curve_center_point)
        distance2 = point.point_distance(curve2.curve_center_point)
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
      x = rectangle.x
      y = rectangle.y
      w = rectangle.width
      h = rectangle.height
      
      # Trivially reject non-existant rectangles
      return false if w <= 0 || h <= 0

      # Trivially accept if either endpoint is inside the rectangle
      # (not on its border since it may end there and not go inside)
      # Record where they lie with respect to the rectangle.
      #     -1 => left, 0 => inside, 1 => right
      x1 = points[0][0]
      y1 = points[0][1]
      x1tag = QuadraticBezierCurve.tag(x1, x, x+w)
      y1tag = QuadraticBezierCurve.tag(y1, y, y+h)
      return true if x1tag == INSIDE && y1tag == INSIDE
      x2 = points[2][0]
      y2 = points[2][1]
      x2tag = QuadraticBezierCurve.tag(x2, x, x+w)
      y2tag = QuadraticBezierCurve.tag(y2, y, y+h)
      return true if x2tag == INSIDE && y2tag == INSIDE
      ctrlx = points[1][0]
      ctrly = points[1][1]
      ctrlxtag = QuadraticBezierCurve.tag(ctrlx, x, x+w)
      ctrlytag = QuadraticBezierCurve.tag(ctrly, y, y+h)

      # Trivially reject if all points are entirely to one side of
      # the rectangle.
      # Returning false means All points left
      return false if x1tag < INSIDE && x2tag < INSIDE && ctrlxtag < INSIDE
      # Returning false means All points above
      return false if y1tag < INSIDE && y2tag < INSIDE && ctrlytag < INSIDE
      # Returning false means All points right
      return false if x1tag > INSIDE && x2tag > INSIDE && ctrlxtag > INSIDE
      # Returning false means All points below
      return false if y1tag > INSIDE && y2tag > INSIDE && ctrlytag > INSIDE

      # Test for endpoints on the edge where either the segment
      # or the curve is headed "inwards" from them
      # Note: These tests are a superset of the fast endpoint tests
      #       above and thus repeat those tests, but take more time
      #       and cover more cases
      # First endpoint on border with either edge moving inside
      return true if inwards(x1tag, x2tag, ctrlxtag) && inwards(y1tag, y2tag, ctrlytag)
      # Second endpoint on border with either edge moving inside
      return true if inwards(x2tag, x1tag, ctrlxtag) && inwards(y2tag, y1tag, ctrlytag)

      # Trivially accept if endpoints span directly across the rectangle
      xoverlap = (x1tag * x2tag <= 0)
      yoverlap = (y1tag * y2tag <= 0)
      return true if x1tag == INSIDE && x2tag == INSIDE && yoverlap
      return true if y1tag == INSIDE && y2tag == INSIDE && xoverlap

      # We now know that both endpoints are outside the rectangle
      # but the 3 points are not all on one side of the rectangle.
      # Therefore the curve cannot be contained inside the rectangle,
      # but the rectangle might be contained inside the curve, or
      # the curve might intersect the boundary of the rectangle.

      eqn = nil
      res = []
      if !yoverlap
          # Both Y coordinates for the closing segment are above or
          # below the rectangle which means that we can only intersect
          # if the curve crosses the top (or bottom) of the rectangle
          # in more than one place and if those crossing locations
          # span the horizontal range of the rectangle.
          eqn = QuadraticBezierCurve.eqn((y1tag < INSIDE ? y : y+h), y1, ctrly, y2)
          return (QuadraticBezierCurve.solve_quadratic(eqn, res) == 2 &&
                  QuadraticBezierCurve.eval_quadratic(res, 2, true, true, nil,
                                x1, ctrlx, x2) == 2 &&
                  QuadraticBezierCurve.tag(res[0], x, x+w) * QuadraticBezierCurve.tag(res[1], x, x+w) <= 0)
      end

      # Y ranges overlap.  Now we examine the X ranges
      if !xoverlap
          # Both X coordinates for the closing segment are left of
          # or right of the rectangle which means that we can only
          # intersect if the curve crosses the left (or right) edge
          # of the rectangle in more than one place and if those
          # crossing locations span the vertical range of the rectangle.
          eqn = QuadraticBezierCurve.eqn((x1tag < INSIDE ? x : x+w), x1, ctrlx, x2)
          return (QuadraticBezierCurve.solve_quadratic(eqn, res) == 2 &&
                  QuadraticBezierCurve.eval_quadratic(res, 2, true, true, nil,
                                y1, ctrly, y2) == 2 &&
                  QuadraticBezierCurve.tag(res[0], y, y+h) * QuadraticBezierCurve.tag(res[1], y, y+h) <= 0)
      end

      # The X and Y ranges of the endpoints overlap the X and Y
      # ranges of the rectangle, now find out how the endpoint
      # line segment intersects the Y range of the rectangle
      dx = x2 - x1
      dy = y2 - y1
      k = y2 * x1 - x2 * y1
      c1tag = c2tag = nil
      if y1tag == INSIDE
        c1tag = x1tag
      else
        c1tag = QuadraticBezierCurve.tag((k + dx * (y1tag < INSIDE ? y : y+h)) / dy, x, x+w)
      end
      if y2tag == INSIDE
        c2tag = x2tag
      else
        c2tag = QuadraticBezierCurve.tag((k + dx * (y2tag < INSIDE ? y : y+h)) / dy, x, x+w)
      end
      # If the part of the line segment that intersects the Y range
      # of the rectangle crosses it horizontally - trivially accept
      return true if c1tag * c2tag <= 0

      # Now we know that both the X and Y ranges intersect and that
      # the endpoint line segment does not directly cross the rectangle.
      #
      # We can almost treat this case like one of the cases above
      # where both endpoints are to one side, except that we will
      # only get one intersection of the curve with the vertical
      # side of the rectangle.  This is because the endpoint segment
      # accounts for the other intersection.
      #
      # (Remember there is overlap in both the X and Y ranges which
      #  means that the segment must cross at least one vertical edge
      #  of the rectangle - in particular, the "near vertical side" -
      #  leaving only one intersection for the curve.)
      #
      # Now we calculate the y tags of the two intersections on the
      # "near vertical side" of the rectangle.  We will have one with
      # the endpoint segment, and one with the curve.  If those two
      # vertical intersections overlap the Y range of the rectangle,
      # we have an intersection.  Otherwise, we don't.

      # c1tag = vertical intersection class of the endpoint segment
      #
      # Choose the y tag of the endpoint that was not on the same
      # side of the rectangle as the subsegment calculated above.
      # Note that we can "steal" the existing Y tag of that endpoint
      # since it will be provably the same as the vertical intersection.
      c1tag = ((c1tag * x1tag <= 0) ? y1tag : y2tag)

      # c2tag = vertical intersection class of the curve
      #
      # We have to calculate this one the straightforward way.
      # Note that the c2tag can still tell us which vertical edge
      # to test against.
      eqn = QuadraticBezierCurve.eqn((c2tag < INSIDE ? x : x+w), x1, ctrlx, x2)
      num = QuadraticBezierCurve.solve_quadratic(eqn, res)

      # Note: We should be able to assert(num == 2) since the
      # X range "crosses" (not touches) the vertical boundary,
      # but we pass num to QuadraticBezierCurve.eval_quadratic for completeness.
      QuadraticBezierCurve.eval_quadratic(res, num, true, true, nil, y1, ctrly, y2)

      # Note: We can assert(num evals == 1) since one of the
      # 2 crossings will be out of the [0,1] range.
      c2tag = QuadraticBezierCurve.tag(res[0], y, y+h)

      # Finally, we have an intersection if the two crossings
      # overlap the Y range of the rectangle.
      c1tag * c2tag <= 0
    end
    
    # Accumulate the number of times the quad crosses the shadow
    # extending to the right of the rectangle.  See the comment
    # for the RECT_INTERSECTS constant for more complete details.
    #
    # crossings arg is the initial crossings value to add to (useful
    # in cases where you want to accumulate crossings from multiple
    # shapes)
    def rect_crossings(rxmin, rymin, rxmax, rymax, level, crossings = 0)
      x0 = points[0][0]
      y0 = points[0][1]
      xc = points[1][0]
      yc = points[1][1]
      x1 = points[2][0]
      y1 = points[2][1]
      return crossings if y0 >= rymax && yc >= rymax && y1 >= rymax
      return crossings if y0 <= rymin && yc <= rymin && y1 <= rymin
      return crossings if x0 <= rxmin && xc <= rxmin && x1 <= rxmin
      if x0 >= rxmax && xc >= rxmax && x1 >= rxmax
        # Quad is entirely to the right of the rect
        # and the vertical range of the 3 Y coordinates of the quad
        # overlaps the vertical range of the rect by a non-empty amount
        # We now judge the crossings solely based on the line segment
        # connecting the endpoints of the quad.
        # Note that we may have 0, 1, or 2 crossings as the control
        # point may be causing the Y range intersection while the
        # two endpoints are entirely above or below.
        if y0 < y1
          # y-increasing line segment...
          crossings += 1 if y0 <= rymin && y1 >  rymin
          crossings += 1 if y0 <  rymax && y1 >= rymax
        elsif y1 < y0
          # y-decreasing line segment...
          crossings -= 1 if y1 <= rymin && y0 >  rymin
          crossings -= 1 if y1 <  rymax && y0 >= rymax
        end
        return crossings
      end
      # The intersection of ranges is more complicated
      # First do trivial INTERSECTS rejection of the cases
      # where one of the endpoints is inside the rectangle.
      return PerfectShape::Rectangle::RECT_INTERSECTS if (x0 < rxmax && x0 > rxmin && y0 < rymax && y0 > rymin) ||
        (x1 < rxmax && x1 > rxmin && y1 < rymax && y1 > rymin)
      # Otherwise, subdivide and look for one of the cases above.
      # double precision only has 52 bits of mantissa
      if level > 52
        line = PerfectShape::Line.new(points: [x0, y0, x1, y1])
        return line.rect_crossings(rxmin, rymin, rxmax, rymax, crossings)
      end
      x0c = BigDecimal((x0 + xc).to_s) / 2
      y0c = BigDecimal((y0 + yc).to_s) / 2
      xc1 = BigDecimal((xc + x1).to_s) / 2
      yc1 = BigDecimal((yc + y1).to_s) / 2
      xc = BigDecimal((x0c + xc1).to_s) / 2
      yc = BigDecimal((y0c + yc1).to_s) / 2
      # [xy]c are NaN if any of [xy]0c or [xy]c1 are NaN
      # [xy]0c or [xy]c1 are NaN if any of [xy][0c1] are NaN
      # These values are also NaN if opposing infinities are added
      return 0 if xc.nan? || yc.nan?
      quad1 = QuadraticBezierCurve.new(points: [x0, y0, x0c, y0c, xc, yc])
      crossings = quad1.rect_crossings(rxmin, rymin, rxmax, rymax, level+1, crossings)
      if crossings != PerfectShape::Rectangle::RECT_INTERSECTS
        quad2 = QuadraticBezierCurve.new(points: [xc, yc, xc1, yc1, x1, y1])
        crossings = quad2.rect_crossings(rxmin, rymin, rxmax, rymax, level+1, crossings)
      end
      crossings
    end
  end
end
