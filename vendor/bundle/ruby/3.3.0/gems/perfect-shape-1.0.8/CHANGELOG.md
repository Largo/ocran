# Change Log

## 1.0.8

- Fix issue with a closed path crashing in `Path#contain?` if the first basic shape is a point array instead of a `PerfectShape::Point` object

## 1.0.7

- Support constructing `PerfectShape::Path` without a point at the beginning
- Support `first_point` method on all shapes to return first point in a shape
- Fix issue in using `Path#contain?` with `outline: true` when `line_to_complex_shapes: true` and path starts with a `Line` instead of a point.

## 1.0.6

- Fix issue with `Path#contain?` algorithm not working correclty when `Path` contains non-basic shapes because `shapes.count` is checked instead of `basic_shapes.count`
- Document `PerfectShape::MultiPoint`

## 1.0.5

- Support Ruby 3.1 by including bundled 'matrix' gem ('>= 0.4.2', '< 1.1.0')

## 1.0.4

- Add missing shapes (`Rectangle` and `Square`) to `Path::SHAPE_TYPES`

## 1.0.3

- `Rectangle` and `Square` `#to_path_shapes` method, which decomposes them into `Point`s and `Line`s to be added to a `Path`
- `Path` can contain a `Rectangle` or `Square` (to get affected by the winding algorithm as opposed to `CompositeShape`, which has no winding algorithm)

## 1.0.2

- `Arc`, `Ellipse`, and `Circle` `#to_path_shapes` method, which decomposes them into `Point`s, `Line`s, and `CubicBezierCurve`s to be added to a `Path`
- `Path` can contain an `Arc`, `Ellipse`, or `Circle` (to get affected by the winding algorithm as opposed to `CompositeShape`, which has no winding algorithm)

## 1.0.1

- Relax `equalizer` gem version to '>= 0.0.11', '< 1.1.0' to avoid conflicts in projects that might use future versions
- Fix issue with infinite loop upon setting `Circle#radius=` to a number with very small decimals
- Fix issue with infinite loop upon setting `Circle#radius_x=` to a number with very small decimals
- Fix issue with infinite loop upon setting `Circle#radius_y=` to a number with very small decimals
- Fix issue with infinite loop upon setting `Circle#diameter=` to a number with very small decimals
- Fix issue with infinite loop upon setting `Circle#width=` to a number with very small decimals
- Fix issue with infinite loop upon setting `Circle#height=` to a number with very small decimals
- Fix issue with infinite loop upon setting `Square#length=` to a number with very small decimals
- Fix issue with infinite loop upon setting `Square#width=` to a number with very small decimals
- Fix issue with infinite loop upon setting `Square#height=` to a number with very small decimals

## 1.0.0

- `PerfectShape::Path#intersect?(rectangle)`
- `PerfectShape::Polygon#intersect?(rectangle)`
- `PerfectShape::CompositeShape#intersect?(rectangle)`
- [API Breaking] Change `Path` default `winding_rule` to `:wind_even_odd`
- Make `PerfectShape::Polygon` support `:wind_non_zero` `winding_rule` (not just default `:wind_even_odd`)

## 0.5.5

- `PerfectShape::Arc#intersect?(rectangle)`
- `PerfectShape::Ellipse#intersect?(rectangle)`
- `PerfectShape::Circle#intersect?(rectangle)`

## 0.5.4

- `PerfectShape::Rectangle#intersect?(rectangle)`
- `PerfectShape::Square#intersect?(rectangle)`
- `PerfectShape::Rectangle#empty?`
- `PerfectShape::Square#empty?`
- `PerfectShape::Square#size`/`PerfectShape::Square#size=` aliases for `#length`/`#length=`

## 0.5.3

- `PerfectShape::CubicBezierCurve#intersect?(rectangle)`
- `PerfectShape::CubicBezierCurve#rectangle_crossings(rectangle)`
- `PerfectShape::CubicBezierCurve#rect_crossings(rxmin, rymin, rxmax, rymax, level, crossings = 0)`
- `PerfectShape::Line#rect_crossings(rxmin, rymin, rxmax, rymax, crossings = 0)`

## 0.5.2

- `PerfectShape::QuadraticBezierCurve#intersect?(rectangle)`
- `PerfectShape::QuadraticBezierCurve::tag(coord, low, high)`
- `PerfectShape::QuadraticBezierCurve::eqn(val, c1, cp, c2)`
- `PerfectShape::QuadraticBezierCurve::solve_quadratic(eqn)`
- `PerfectShape::QuadraticBezierCurve::eval_quadratic(vals, num, include0, include1, inflect, c1, ctrl, c2)`

## 0.5.1

- `PerfectShape::Point#intersect?(rectangle)` (equivalent to `PerfectShape::Rectangle#contain?(point)`)

## 0.5.0

- `PerfectShape::Line#intersect?(rectangle)`
- `PerfectShape::Rectangle#out_state(x_or_point, y = nil)`

## 0.4.0

- `PerfectShape::AffineTransform#new`
- `PerfectShape::AffineTransform#==`
- `PerfectShape::AffineTransform#transform_point`
- `PerfectShape::AffineTransform#transform_points`
- `PerfectShape::AffineTransform#identity!` (alias: `reset!`)
- `PerfectShape::AffineTransform#invert!`
- `PerfectShape::AffineTransform#invertible?`
- `PerfectShape::AffineTransform#multiply!`
- `PerfectShape::AffineTransform#translate!`
- `PerfectShape::AffineTransform#scale!`
- `PerfectShape::AffineTransform#rotate!`
- `PerfectShape::AffineTransform#shear!` (alias: `skew!`)
- `PerfectShape::AffineTransform#clone`
- `PerfectShape::AffineTransform#inverse_transform_point`
- `PerfectShape::AffineTransform#inverse_transform_points`

## 0.3.5

- Check point containment in composite shape outline with distance tolerance (new method signature: `PerfectShape::CompositeShape#contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)`)

## 0.3.4

- Check point containment in path outline with distance tolerance (new method signature: `PerfectShape::Path#contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)`)
- `PerfectShape::Path#disconnected_shapes`: Disconnected shapes have their start point filled in so that each shape does not depend on the previous shape to determine its start point.
- `Shape#center_point` as `[center_x, center_y]`
- Rename `#point_segment_distance` to `#point_distance` everywhere

## 0.3.3

- Check point containment in quadratic bezier curve outline with distance tolerance (new method signature: `PerfectShape::QuadraticBezierCurve#contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)`)
- `PerfectShape::QuadraticBezierCurve#curve_center_point`, `PerfectShape::QuadraticBezierCurve#curve_center_x`, `PerfectShape::QuadraticBezierCurve#curve_center_y`
- `PerfectShape::QuadraticBezierCurve#subdivisions(level=1)`
- `PerfectShape::QuadraticBezierCurve#point_distance(x_or_point, y = nil, minimum_distance_threshold: OUTLINE_MINIMUM_DISTANCE_THRESHOLD)`
- `PerfectShape::Polygon#edges` returns edges of polygon as `PerfectShape::Line` objects
- `PerfectShape::Rectangle#edges` returns edges of rectangle as `PerfectShape::Line` objects
- `PerfectShape::Square#edges` returns edges of square as `PerfectShape::Line` objects
- Rename `number` arg to `level` in `CubicBezierCurve#subdivisions(level=1)`, making it signify the level of subdivision recursion to perform.

## 0.3.2

- Check point containment in cubic bezier curve outline with distance tolerance (new method signature: `PerfectShape::CubicBezierCurve#contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)`)
- `PerfectShape::CubicBezierCurve#curve_center_point`, `PerfectShape::CubicBezierCurve#curve_center_x`, `PerfectShape::CubicBezierCurve#curve_center_y`
- `PerfectShape::CubicBezierCurve#subdivisions(level=1)`
- `PerfectShape::CubicBezierCurve#point_distance(x_or_point, y = nil, minimum_distance_threshold: OUTLINE_MINIMUM_DISTANCE_THRESHOLD)`

## 0.3.1

- Check point containment in arc outline with distance tolerance (new method signature: `PerfectShape::Arc#contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)`)
- Check point containment in ellipse outline with distance tolerance (new method signature: `PerfectShape::Ellipse#contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)`)
- Check point containment in circle outline with distance tolerance (new method signature: `PerfectShape::Circle#contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)`)

## 0.3.0

- Refactoring: rename `distance` option for `#contain?` on `Point`/`Line` into `distance_tolerance`
- Check point containment in rectangle outline with distance tolerance (new method signature: `PerfectShape::Rectangle#contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)`)
- Check point containment in square outline with distance tolerance (new method signature: `PerfectShape::Square#contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)`)
- Check point containment in polygon outline with distance tolerance (new method signature: `PerfectShape::Polygon#contain?(x_or_point, y = nil, outline: false, distance_tolerance: 0)`)

## 0.2.0

- `PerfectShape::CompositeShape`: aggregate of multiple shapes
- `PerfectShape::CompositeShape#contain?(x_or_point, y=nil)`
- `PerfectShape::CompositeShape#==`

## 0.1.2

- `PerfectShape::CubicBezierCurve` (two end points and two control points)
- `PerfectShape::CubicBezierCurve#contain?(x_or_point, y=nil)`
- `PerfectShape::CubicBezierCurve#==`
- `PerfectShape::Path` having cubic bezier curves in addition to points, lines, and quadratic bezier curves

## 0.1.1

- `PerfectShape::QuadraticBezierCurve` (two end points and one control point)
- `PerfectShape::QuadraticBezierCurve#contain?(x_or_point, y=nil)`
- `PerfectShape::QuadraticBezierCurve#==`
- `PerfectShape::Path` having quadratic bezier curves in addition to points and lines

## 0.1.0

- `PerfectShape::Path` (having points or lines)
- `PerfectShape::Path#contain?(x_or_point, y=nil, distance_tolerance: 0)`
- `PerfectShape::Path#point_crossings(x_or_point, y=nil)`
- `PerfectShape::Path#==`

## 0.0.11

- `PerfectShape::Polygon#==`
- `PerfectShape::Line#==`
- `PerfectShape::Point#==`

## 0.0.10

- `PerfectShape::Point`
- `PerfectShape::Point#point_distance`
- `PerfectShape::Point#contain?(x_or_point, y=nil, distance_tolerance: 0)`
- Refactor `PerfectShape::Point`,`PerfectShape::RectangularShape` to include shared `PerfectShape::PointLocation`

## 0.0.9

- `PerfectShape::Line#contain?(x_or_point, y=nil, distance_tolerance: 0)` (add a distance tolerance fuzz factor option)

## 0.0.8

- `PerfectShape::Line`
- `PerfectShape::Line#contain?(x_or_point, y=nil)`
- `PerfectShape::Line#relative_counterclockwise`
- `PerfectShape::Line#point_distance`
- Update `PerfectShape::Math::radians_to_degrees`, `PerfectShape::Math::degrees_to_radians`, and `PerfectShape::Math::normalize_degrees` to normalize numbers to `BigDecimal`

## 0.0.7

- `PerfectShape::Polygon`
- `PerfectShape::Polygon#contain?(x_or_point, y)` (Ray Casting Algorithm, aka Even-Odd Rule)
- `PerfectShape::Shape#min_x`/`PerfectShape::Shape#min_y`/`PerfectShape::Shape#max_x`/`PerfectShape::Shape#max_y`/`PerfectShape::Shape#center_x`/`PerfectShape::Shape#center_y`/`PerfectShape::Shape#bounding_box`

## 0.0.6

- `PerfectShape::Circle`
- `PerfectShape::Circle#contain?(x_or_point, y=nil)`

## 0.0.5

- `PerfectShape::Ellipse`
- `PerfectShape::Ellipse#contain?(x_or_point, y=nil)`

## 0.0.4

- `PerfectShape::Arc#center_x` / `PerfectShape::Arc#center_y` / `PerfectShape::Arc#radius_x` / `PerfectShape::Arc#radius_y`
- `PerfectShape::Rectangle#center_x` / `PerfectShape::Arc#center_y`
- `PerfectShape::Square#center_x` / `PerfectShape::Square#center_y`
- `PerfectShape::Arc#initialize(center_x: , center_y: , radius_x: , radius_y: )`
- `PerfectShape::Math::normalize_degrees(degrees)` extracted from `PerfectShape::Arc`

## 0.0.3

- `PerfectShape::Square`
- `PerfectShape::Square#contain?(x_or_point, y=nil)`

## 0.0.2

- `PerfectShape::Rectangle`
- `PerfectShape::Rectangle#contain?(x_or_point, y=nil)`

## 0.0.1

- `PerfectShape::Math`
- `PerfectShape::Math::ieee_remainder` (alias: `ieee754_remainder`)
- `PerfectShape::Math::degrees_to_radians(angle)`
- `PerfectShape::Math::radians_to_degrees(angle)`
- `PerfectShape::Line`
- `PerfectShape::Line::relative_ccw(x1, y1, x2, y2, px, py)`
- `PerfectShape::Arc`
- `PerfectShape::Arc#contain?(x_or_point, y=nil)`
