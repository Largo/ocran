# -*- encoding: utf-8 -*-
# stub: glimmer 2.8.1 ruby lib

Gem::Specification.new do |s|
  s.name = "glimmer".freeze
  s.version = "2.8.1".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["AndyMaleh".freeze]
  s.date = "2025-03-21"
  s.description = "Glimmer is a Ruby DSL Framework for Ruby GUI and More, consisting of a DSL Engine and a Data-Binding Library (including Observer Design Pattern, Observable Model, Observable Array, and Observable Hash). Used in Glimmer DSL for SWT (JRuby Desktop Development GUI Framework), Glimmer DSL for Web (Ruby in the Browser Web Frontend Framework and Winner of Fukuoka Prefecture Future IT Initiative 2025 Money Forward Award), Glimmer DSL for LibUI (Prerequisite-Free Ruby Desktop Development GUI Library and Winner of Fukuoka Ruby Award Competition 2022 Special Award), Glimmer DSL for Tk (Ruby Tk Desktop Development GUI Library), Glimmer DSL for GTK (Ruby-GNOME Desktop Development GUI Library), Glimmer DSL for FX (FOX Toolkit Ruby Desktop Development GUI Library), Glimmer DSL for WX (wxWidgets Ruby Desktop Development GUI Library), Glimmer DSL for Swing (JRuby Swing Desktop Development GUI Library), Glimmer DSL for JFX (JRuby JavaFX Desktop Development GUI Library), Glimmer DSL for XML (& HTML), and Glimmer DSL for CSS.".freeze
  s.email = "andy.am@gmail.com".freeze
  s.extra_rdoc_files = ["CHANGELOG.md".freeze, "LICENSE.txt".freeze, "README.md".freeze]
  s.files = ["CHANGELOG.md".freeze, "LICENSE.txt".freeze, "README.md".freeze]
  s.homepage = "http://github.com/AndyObtiva/glimmer".freeze
  s.licenses = ["MIT".freeze]
  s.rubygems_version = "3.6.2".freeze
  s.summary = "Glimmer (DSL Framework for Ruby GUI and More)".freeze

  s.installed_by_version = "3.6.7".freeze

  s.specification_version = 4

  s.add_runtime_dependency(%q<array_include_methods>.freeze, [">= 1.4.0".freeze, "< 1.6.0".freeze])
  s.add_runtime_dependency(%q<facets>.freeze, [">= 3.1.0".freeze, "< 4.0.0".freeze])
  s.add_development_dependency(%q<rspec-mocks>.freeze, ["~> 3.5.0".freeze])
  s.add_development_dependency(%q<rspec>.freeze, ["~> 3.5.0".freeze])
  s.add_development_dependency(%q<puts_debuggerer>.freeze, [">= 1.0.1".freeze])
  s.add_development_dependency(%q<rake>.freeze, [">= 10.1.0".freeze, "< 14.0.0".freeze])
  s.add_development_dependency(%q<jeweler>.freeze, [">= 2.0.0".freeze, "< 3.0.0".freeze])
  s.add_development_dependency(%q<rdoc>.freeze, [">= 6.2.1".freeze, "< 7.0.0".freeze])
  s.add_development_dependency(%q<coveralls>.freeze, [">= 0".freeze])
  s.add_development_dependency(%q<simplecov>.freeze, ["~> 0.16.1".freeze])
  s.add_development_dependency(%q<simplecov-lcov>.freeze, ["~> 0.7.0".freeze])
  s.add_development_dependency(%q<rake-tui>.freeze, ["> 0".freeze])
end
