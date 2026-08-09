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

require 'perfect_shape/rectangle'

module PerfectShape
  class Square < Rectangle
    MESSAGE_WIDTH_AND_HEIGHT_AND_LENGTH_NOT_EQUAL = 'Square width, height, and length must all be equal if more than one is specified; or otherwise keep only one of them in constructor arguments!'
  
    attr_reader :length
    alias size length
    
    # Constructs with x, y, length (optionally width or height can be passed as alias for length)
    def initialize(x: 0, y: 0, length: nil, size: nil, width: nil, height: nil)
      raise MESSAGE_WIDTH_AND_HEIGHT_AND_LENGTH_NOT_EQUAL if (length && size && length != size)
      length ||= size
      raise MESSAGE_WIDTH_AND_HEIGHT_AND_LENGTH_NOT_EQUAL if (length && width && length != width) || (length && height && length != height) || (width && height && width != height)
      length ||= width || height || 1
      super(x: x, y: y, width: length, height: length)
    end
    
    # Sets length, normalizing to BigDecimal
    def length=(value)
      @length = BigDecimal(value.to_s)
      self.width = @length unless width == @length
      self.height = @length unless height == @length
    end
    alias size= length=
    
    def width=(value)
      super
      self.length = @width unless length == @width
      self.height = @width unless height == @width
    end
    
    def height=(value)
      super
      self.length = @height unless length == @height
      self.width = @height unless width == @height
    end
  end
end
