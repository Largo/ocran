require File.expand_path('../lib/text-table/version', __FILE__)

Gem::Specification.new do |gem|
  gem.name = 'text-table'
  gem.version = Text::Table::VERSION
  gem.authors = ['Aaron Tinio']
  gem.email = 'aptinio@gmail.com'
  gem.summary = 'A feature-rich, easy-to-use plain text table formatter.'
  gem.description = %w[
    Allows you to easily create and format plain text tables,
    useful when working with the terminal or when you want to quickly print
    formatted tables to a dot-matrix printer.
  ].join ' '
  gem.homepage = 'https://github.com/aptinio/text-table'

  gem.require_paths = ['lib']
  gem.files = `git ls-files`.split($/)
  gem.test_files = `git ls-files -- spec/*`.split($/)
  gem.extra_rdoc_files = %w[LICENSE README.rdoc]
  gem.add_development_dependency 'rspec', '~> 2'
  gem.license = 'MIT'
end
