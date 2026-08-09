# -*- encoding: utf-8 -*-
# stub: super_module 1.4.2 ruby lib

Gem::Specification.new do |s|
  s.name = "super_module".freeze
  s.version = "1.4.2".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Andy Maleh".freeze]
  s.date = "2024-07-28"
  s.description = "SuperModule allows defining class methods and method invocations the same way a super class does without using def included(base). This also succeeds ActiveSupport::Concern by offering lighter syntax".freeze
  s.extra_rdoc_files = ["CHANGELOG.md".freeze, "LICENSE.txt".freeze, "README.md".freeze]
  s.files = ["CHANGELOG.md".freeze, "LICENSE.txt".freeze, "README.md".freeze]
  s.homepage = "http://github.com/AndyObtiva/super_module".freeze
  s.licenses = ["MIT".freeze]
  s.rubygems_version = "3.3.5".freeze
  s.summary = "SuperModule allows defining class methods and method invocations the same way a super class does without using def included(base). This also succeeds ActiveSupport::Concern by offering lighter syntax".freeze

  s.installed_by_version = "3.6.7".freeze

  s.specification_version = 4

  s.add_runtime_dependency(%q<method_source>.freeze, [">= 0.8.2".freeze, "< 2.0.0".freeze])
  s.add_development_dependency(%q<jeweler>.freeze, ["~> 2.3.0".freeze])
  s.add_development_dependency(%q<rdoc>.freeze, ["~> 4.2.0".freeze])
  s.add_development_dependency(%q<rspec>.freeze, ["~> 3.2.0".freeze])
  s.add_development_dependency(%q<puts_debuggerer>.freeze, ["> 0.8.1".freeze])
  s.add_development_dependency(%q<rake>.freeze, ["~> 10.4.2".freeze])
  s.add_development_dependency(%q<rack>.freeze, ["~> 1.6.5".freeze])
  s.add_development_dependency(%q<tins>.freeze, ["~> 1.6.0".freeze])
  s.add_development_dependency(%q<term-ansicolor>.freeze, ["~> 1.3.2".freeze])
end
