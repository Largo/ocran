# -*- encoding: utf-8 -*-
# stub: array_include_methods 1.5.1 ruby lib

Gem::Specification.new do |s|
  s.name = "array_include_methods".freeze
  s.version = "1.5.1".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Andy Maleh".freeze]
  s.date = "2023-02-17"
  s.description = "Array#include_all?, Array#include_any?, Array#include_array?, Array#array_index, Array#counts, and Array#duplicates methods missing from basic Ruby Array API. Compatible with Ruby, JRuby, Opal, and RubyMotion.".freeze
  s.email = "andy.am@gmail.com".freeze
  s.extra_rdoc_files = ["CHANGELOG.md".freeze, "LICENSE.txt".freeze, "README.md".freeze]
  s.files = ["CHANGELOG.md".freeze, "LICENSE.txt".freeze, "README.md".freeze]
  s.homepage = "http://github.com/AndyObtiva/array_include_methods".freeze
  s.licenses = ["MIT".freeze]
  s.rubygems_version = "3.3.3".freeze
  s.summary = "Array#include_all?, Array#include_any?, and other methods missing from basic Ruby Array API".freeze

  s.installed_by_version = "3.6.7".freeze

  s.specification_version = 4

  s.add_development_dependency(%q<rspec>.freeze, ["~> 3.5.0".freeze])
  s.add_development_dependency(%q<rdoc>.freeze, ["~> 3.12".freeze])
  s.add_development_dependency(%q<jeweler>.freeze, ["~> 2.3.9".freeze])
  s.add_development_dependency(%q<coveralls>.freeze, ["= 0.8.23".freeze])
  s.add_development_dependency(%q<simplecov>.freeze, ["~> 0.16.1".freeze])
  s.add_development_dependency(%q<simplecov-lcov>.freeze, ["~> 0.7.0".freeze])
  s.add_development_dependency(%q<puts_debuggerer>.freeze, ["> 0".freeze])
  s.add_development_dependency(%q<rake-tui>.freeze, ["> 0".freeze])
end
