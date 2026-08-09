if ['opal', 'rubymotion'].include?(RUBY_ENGINE)
  # Create a shim using method that does nothing since we monkey-patch in Opal earlier in `refine` method
  def self.using(refinement)
    # NO OP
  end

  module ArrayIncludeMethods
    def self.refine(class_or_module, &refinement)
      class_or_module.class_eval(&refinement)
    end
  end
end

module ArrayIncludeMethods
  refine Array do
    # Returns `true` if all of the given `array` elements are present in `self`,
    # otherwise returns `false`
    # Always returns `true` if the given `array` is empty
    # `same_sort` kwarg indicates that array must have the same sort as `self`. By default, it is `false`
    # e.g. [1,2,3].include_all?(2,3, same_sort: true) => true
    def include_all?(*array)
      options = array.last.is_a?(Hash) && array.last.has_key?(:same_sort) ? array.pop : {same_sort: false}
      same_sort = options[:same_sort]
      return false if array.size > self.size
      self_copy = self.dup
      array_copy = array.dup
      book_keeping_array_copy = array.dup
      self_element_index = last_element_index = -1
      array_copy.each do |element|
        if self_copy.include?(element)
          last_element_index = self_element_index
          self_element_index = self_copy.index(element)
          return false if same_sort && self_element_index < last_element_index
          self_copy.delete_at(self_element_index)
          book_keeping_array_copy.delete(element)
        else
          return false
        end
      end
      book_keeping_array_copy.empty?
    end

    # Returns `true` if the given `array` is present in `self` (in the same element order without repetition)
    # Always returns `true` if the given `array` is empty
    # Always returns `false` if the given `array` is nil
    def include_array?(array)
      return false if array.nil?
      if array.size > self.size
        false
      else
        size_diff = self.size - array.size
        (size_diff + 1).times.any? do |start_index|
          self[start_index, array.size] == array
        end
      end
    end

    # Returns `true` if any of the given `array` elements are present in `self`,
    # otherwise returns `false`
    # Always returns `true` if the given `array` is empty
    def include_any?(*array)
      !array.nil? && (array.empty? || !(self & array).empty?)
    end
    
    def array_index(array)
      result_array_index = -1
      return result_array_index if array.nil?
      if array.size <= self.size
        size_diff = self.size - array.size
        current_array_index = nil
        result = (size_diff + 1).times.any? do |start_index|
          current_array_index = start_index
          self[start_index, array.size] == array
        end
        result_array_index = current_array_index if result
      end
      result_array_index
    end
    
    def array_intersection_indexes(array)
      array_intersection_and_diff_indexes(array)[:intersection_indexes]
    end
    alias array_intersection_indices array_intersection_indexes
    
    def array_intersection(array)
      array_intersection_indexes(array).map { |index| self[index] }
    end
    
    def array_diff_indexes(array)
      array_intersection_and_diff_indexes(array)[:diff_indexes]
    end
    alias array_diff_indices array_diff_indexes
    alias array_difference_indexes array_diff_indexes
    alias array_difference_indices array_diff_indexes
    
    def array_diff(array)
      array_diff_indexes(array).map { |index| self[index] }
    end
    alias array_difference array_diff
    
    # Returns a hash of counts of every element in the array,
    # performed in linear time (running time of O(n))
    def counts
      inject({}) do |count_hash, element|
        count_hash[element] ||= 0
        count_hash[element] += 1
        count_hash
      end
    end
    
    # Returns a single occurrence of all elements that repeated in an array,
    # performed in linear time (running time of O(n)).
    def duplicates
      counts.select { |element, count| count > 1 }.keys
    end
    
    private
    
    def array_intersection_and_diff_indexes(array)
      return {intersection_indexes: [], diff_indexes: self.size.times.to_a} if array.nil?
      intersection_indexes = []
      diff_indexes = []
      array_current_index = 0
      each_with_index do |element, index|
        if element == array[array_current_index]
          intersection_indexes << index
          array_current_index += 1
        else
          diff_indexes << index
        end
      end
      {
        intersection_indexes: intersection_indexes,
        diff_indexes: diff_indexes
      }
    end
  end
end
