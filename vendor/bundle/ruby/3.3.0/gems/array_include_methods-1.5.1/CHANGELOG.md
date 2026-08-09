# Change Log

## 1.5.1

- `counts` returns a hash of counts of every element in the array, performed in linear time (running time of O(n)).
- `duplicates` returns a single occurrence of all elements that repeated in an array
- `array_difference_indices`/`array_difference_indexes` aliases for `array_diff_indices`/`array_diff_indexes`
- `array_diff`/`array_difference` (return elements of `array_diff_indexes`)
- `array_intersection` (returns elements of `array_intersection_indexes`)

## 1.5.0

- Add RubyMotion compatibility
- Ensure Opal compatibility happens through RUBY_ENGINE instead of RUBY_PLATFORM

## 1.4.0

- `array_diff_indexes(other_array)` (alias: `array_diff_indices`)
- `array_intersection_indexes(other_array)` (alias: `array_intersection_indices`)

## 1.3.0

- [API Breaking] Separate between operations `include_any?(*array)` and `include_any?(array)` to avoid confusion (remove support for the latter as it is not necessary)
- [API Breaking] Separate between operations `include_all?(*array)` and `include_all?(array)` to avoid confusion (rename the latter to `include_array?(array)`)
- `Array#include_all?(*other_array, same_sort: true)` accepts `same_sort` option (default: `false`)

## 1.2.0

- Add `Array#array_index(array)` method to determine start array index of other array

## 1.1.0

- Perform contiguous-element `include_all?([...])` check against an array argument (not splatted)
- Perform sorted `include_all?([...])` check against an array argument (not splatted)
- Perform non-repetition `include_all?([...])` check against an array argument (not splatted)

## 1.0.4

- Support splat args (e.g. `include_any?(1, 2, 3)` instead of `include_any?([1, 2, 3])`)

## 1.0.3

- Opal compatibility through monkey-patching and providing a `using` method shim so that existing gems that used the refinement in Ruby work

## 1.0.2

- Handled case of two arrays with elements of unsortable object types (e.g. Hash)

## 1.0.1

- Handled case of two arrays with different ordering of common elements

## 1.0.0

- Initial implementation of Array#include_all? & Array#include_any?
