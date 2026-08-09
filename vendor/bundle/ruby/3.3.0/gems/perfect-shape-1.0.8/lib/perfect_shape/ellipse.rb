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

require 'perfect_shape/arc'

module PerfectShape
  class Ellipse < Arc
    MESSAGE_CANNOT_UPDATE_ATTRIUBTE = "Ellipse %s cannot be updated. If you want to update type, use Arc instead!"
    
    def initialize(x: 0, y: 0, width: 1, height: 1, center_x: nil, center_y: nil, radius_x: nil, radius_y: nil)
      super
      @initialized = true
    end
    
    def type=(value)
      if @initialized
        raise MESSAGE_CANNOT_UPDATE_ATTRIUBTE % 'type'
      else
        super
      end
    end
    
    def start=(value)
      if @initialized
        raise MESSAGE_CANNOT_UPDATE_ATTRIUBTE % 'start'
      else
        super
      end
    end
    
    def extent=(value)
      if @initialized
        raise MESSAGE_CANNOT_UPDATE_ATTRIUBTE % 'extent'
      else
        super
      end
    end
    
    # Checks if ellipse contains point (two-number Array or x, y args)
    #
    # @param x The X coordinate of the point to test.
    # @param y The Y coordinate of the point to test.
    #
    # @return true if the point lies within the bound of
    # the ellipse, false if the point lies outside of the
    # ellipse's bounds.
    def contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)
      # This is implemented again even though super would have just worked to have an optimized algorithm for Ellipse.
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      if outline
        super(x, y, outline: true, distance_tolerance: distance_tolerance)
      else
        ellw = self.width
        return false if ellw <= 0.0
        normx = (x - self.x) / ellw - 0.5
        ellh = self.height
        return false if ellh <= 0.0
        normy = (y - self.y) / ellh - 0.5
        (normx * normx + normy * normy) < 0.25
      end
    end
  end
end
