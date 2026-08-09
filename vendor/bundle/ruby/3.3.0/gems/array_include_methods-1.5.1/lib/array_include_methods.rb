begin
  Motion::Project::App.setup do |app|
    app.files += [File.join(__dir__, 'array_include_methods', 'array.rb')]
  end
rescue
  require_relative 'array_include_methods/array'
end
