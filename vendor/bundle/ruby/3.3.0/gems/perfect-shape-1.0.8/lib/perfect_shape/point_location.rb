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

module PerfectShape
  # Point location usually represents the top-left point in a shape
  module PointLocation
    attr_reader :x, :y
    
    # Calls super before setting x,y (default: 0,0)
    def initialize(x: 0, y: 0)
      super()
      self.x = x
      self.y = y
    end
    
    def first_point
      [x, y]
    end
    
    # Sets x, normalizing to BigDecimal
    def x=(value)
      @x = BigDecimal(value.to_s)
    end
    
    # Sets y, normalizing to BigDecimal
    def y=(value)
      @y = BigDecimal(value.to_s)
    end
    
    # Returns x by default. Subclasses may override.
    def min_x
      x
    end
    
    # Returns y by default. Subclasses may override.
    def min_y
      y
    end
  end
end
