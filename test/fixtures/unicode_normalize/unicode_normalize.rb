# String#unicode_normalize is core Ruby, but its implementation is loaded
# from the standard library (unicode_normalize/normalize.rb) on first use.
# It is called only in the packed app, never during OCRAN's dependency run.
unless defined?(Ocran)
  puts "é".unicode_normalize(:nfd).codepoints.map { |c| format("U+%04X", c) }.join(" ")

  # A Ruby that is not relocatable (most Linux builds) still has the build
  # host's standard library on its load path and would find the file there,
  # so report where it came from: the package root is the parent of src/.
  # Compared as case-folded realpaths: on Windows the two can differ in case
  # or in short (8.3) versus long directory names.
  root = File.realpath(File.expand_path("..", __dir__)).downcase
  loaded = $LOADED_FEATURES.grep(%r{/unicode_normalize/normalize\.rb\z})
  inside = loaded.size == 1 && File.realpath(loaded.first).downcase.start_with?("#{root}/")
  puts inside ? "packed" : "not packed: #{loaded.inspect}"
end
