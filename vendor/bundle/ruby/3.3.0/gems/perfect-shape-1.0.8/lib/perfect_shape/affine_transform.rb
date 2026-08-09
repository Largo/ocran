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

require 'perfect_shape/math'
require 'perfect_shape/shape'
require 'perfect_shape/point'
require 'perfect_shape/multi_point'

module PerfectShape
  # Represents an affine transform
  class AffineTransform
    include Equalizer.new(:xxp, :xyp, :yxp, :yyp, :xt, :yt)
  
    attr_reader :xxp, :xyp, :yxp, :yyp, :xt, :yt
    alias m11 xxp
    alias m12 xyp
    alias m21 yxp
    alias m22 yyp
    alias m13 xt
    alias m23 yt
  
    # Creates a new AffineTransform with the following Matrix:
    #
    # [ xxp xyp xt ]
    # [ yxp yyp yt ]
    #
    # The Matrix is used to transform (x,y) point coordinates as follows:
    #
    # [ xxp xyp xt ] * [x] = [ xxp * x + xyp * y + xt ]
    # [ yxp yyp yt ] * [y] = [ yxp * x + yyp * y + yt ]
    #
    # xxp is the x coordinate x product (m11)
    # xyp is the x coordinate y product (m12)
    # yxp is the y coordinate x product (m21)
    # yyp is the y coordinate y product (m22)
    # xt is the x coordinate translation (m13)
    # yt is the y coordinate translation (m23)
    #
    # The constructor accepts either the (x,y)-operation related argument/kwarg names
    # or traditional Matrix element kwarg names
    #
    # Example with (x,y)-operation kwarg names:
    #
    # AffineTransform.new(xxp: 2, xyp: 3, yxp: 4, yyp: 5, xt: 6, yt: 7)
    #
    # Example with traditional Matrix element kwarg names:
    #
    # AffineTransform.new(m11: 2, m12: 3, m21: 4, m22: 5, m13: 6, m23: 7)
    #
    # Example with standard arguments:
    #
    # AffineTransform.new(2, 3, 4, 5, 6, 7)
    #
    # If no arguments are supplied, it constructs an identity matrix
    # (i.e. like calling `::new(xxp: 1, xyp: 0, yxp: 0, yyp: 1, xt: 0, yt: 0)`)
    def initialize(xxp_element = nil, xyp_element = nil, yxp_element = nil, yyp_element = nil, xt_element = nil, yt_element = nil,
                   xxp: nil, xyp: nil, yxp: nil, yyp: nil, xt: nil, yt: nil,
                   m11: nil, m12: nil, m21: nil, m22: nil, m13: nil, m23: nil)
      self.xxp = xxp_element || xxp || m11 || 1
      self.xyp = xyp_element || xyp || m12 || 0
      self.yxp = yxp_element || yxp || m21 || 0
      self.yyp = yyp_element || yyp || m22 || 1
      self.xt  = xt_element  || xt  || m13 || 0
      self.yt  = yt_element  || yt  || m23 || 0
    end
    
    def xxp=(value)
      @xxp = BigDecimal(value.to_s)
    end
    alias m11= xxp=
    
    def xyp=(value)
      @xyp = BigDecimal(value.to_s)
    end
    alias m12= xyp=
    
    def yxp=(value)
      @yxp = BigDecimal(value.to_s)
    end
    alias m21= yxp=
    
    def yyp=(value)
      @yyp = BigDecimal(value.to_s)
    end
    alias m22= yyp=
    
    def xt=(value)
      @xt = BigDecimal(value.to_s)
    end
    alias m13= xt=
    
    def yt=(value)
      @yt = BigDecimal(value.to_s)
    end
    alias m23= yt=
    
    # Resets to identity matrix
    # Returns self to support fluent interface chaining
    def identity!
      self.xxp = 1
      self.xyp = 0
      self.yxp = 0
      self.yyp = 1
      self.xt  = 0
      self.yt  = 0
      
      self
    end
    alias reset! identity!

    # Inverts AffineTransform matrix if invertible
    # Raises an error if affine transform matrix is not invertible
    # Returns self to support fluent interface chaining
    def invert!
      raise 'Cannot invert (matrix is not invertible)!' if !invertible?
      
      self.matrix_3d = matrix_3d.inverse
      
      self
    end
    
    def invertible?
      (m11 * m22 - m12 * m21) != 0
    end
    
    # Multiplies by other AffineTransform
    def multiply!(other_affine_transform)
      self.matrix_3d = matrix_3d*other_affine_transform.matrix_3d
      
      self
    end
    
    # Translates AffineTransform
    def translate!(x_or_point, y = nil)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      
      translation_affine_transform = AffineTransform.new(xxp: 1, xyp: 0, yxp: 0, yyp: 1, xt: x, yt: y)
      multiply!(translation_affine_transform)
      
      self
    end
    
    # Scales AffineTransform
    def scale!(x_or_point, y = nil)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      
      scale_affine_transform = AffineTransform.new(xxp: x, xyp: 0, yxp: 0, yyp: y, xt: 0, yt: 0)
      multiply!(scale_affine_transform)
      
      self
    end
    
    # Rotates AffineTransform counter-clockwise for positive angle value in degrees
    # or clockwise for negative angle value in degrees
    def rotate!(degrees)
      degrees = Math.normalize_degrees(degrees)
      radians = Math.degrees_to_radians(degrees)
      
      rotation_affine_transform = AffineTransform.new(xxp: Math.cos(radians), xyp: -Math.sin(radians), yxp: Math.sin(radians), yyp: Math.cos(radians), xt: 0, yt: 0)
      multiply!(rotation_affine_transform)
      
      self
    end
    
    # Shears AffineTransform by (x,y) amount
    def shear!(x_or_point, y = nil)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      
      shear_affine_transform = AffineTransform.new(xxp: 1 + x*y, xyp: x, yxp: y, yyp: 1, xt: 0, yt: 0)
      multiply!(shear_affine_transform)
      
      self
    end
    alias skew! shear!
    
    # Sets elements from a Ruby Matrix representing Affine Transform matrix elements in 3D
    def matrix_3d=(the_matrix_3d)
      self.xxp = the_matrix_3d[0, 0]
      self.xyp = the_matrix_3d[0, 1]
      self.xt = the_matrix_3d[0, 2]
      self.yxp = the_matrix_3d[1, 0]
      self.yyp = the_matrix_3d[1, 1]
      self.yt = the_matrix_3d[1, 2]
    end
    
    # Returns Ruby Matrix representing Affine Transform matrix elements in 3D
    def matrix_3d
      Matrix[[xxp, xyp, xt], [yxp, yyp, yt], [0, 0, 1]]
    end
    
    def transform_point(x_or_point, y = nil)
      x, y = Point.normalize_point(x_or_point, y)
      return unless x && y
      
      [xxp*x + xyp*y + xt, yxp*x + yyp*y + yt]
    end
    
    def inverse_transform_point(x_or_point, y = nil)
      clone.invert!.transform_point(x_or_point, y)
    end
    
    def transform_points(*xy_coordinates_or_points)
      points = xy_coordinates_or_points.first.is_a?(Array) ? xy_coordinates_or_points.first : xy_coordinates_or_points
      points = MultiPoint.normalize_point_array(points)
      points.map { |point| transform_point(point) }
    end
    
    def inverse_transform_points(*xy_coordinates_or_points)
      points = xy_coordinates_or_points.first.is_a?(Array) ? xy_coordinates_or_points.first : xy_coordinates_or_points
      points = MultiPoint.normalize_point_array(points)
      points.map { |point| inverse_transform_point(point) }
    end
  end
end
