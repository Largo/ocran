# -*- encoding: utf-8 -*-
# stub: rake-tui 0.2.3 ruby lib

Gem::Specification.new do |s|
  s.name = "rake-tui".freeze
  s.version = "0.2.3".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["AndyMaleh".freeze]
  s.date = "2020-09-24"
  s.description = "Rake Text-based User Interface".freeze
  s.email = "andy.am@gmail.com".freeze
  s.executables = ["rake-tui".freeze, "jrake-tui".freeze, "raketui".freeze, "jraketui".freeze, "rake-ui".freeze, "jrake-ui".freeze, "rakeui".freeze, "jrakeui".freeze]
  s.extra_rdoc_files = ["CHANGELOG.md".freeze, "LICENSE.txt".freeze, "README.md".freeze]
  s.files = ["CHANGELOG.md".freeze, "LICENSE.txt".freeze, "README.md".freeze, "bin/jrake-tui".freeze, "bin/jrake-ui".freeze, "bin/jraketui".freeze, "bin/jrakeui".freeze, "bin/rake-tui".freeze, "bin/rake-ui".freeze, "bin/raketui".freeze, "bin/rakeui".freeze]
  s.homepage = "http://github.com/AndyObtiva/rake-tui".freeze
  s.licenses = ["MIT".freeze]
  s.rubygems_version = "3.1.4".freeze
  s.summary = "Rake TUI".freeze

  s.installed_by_version = "3.6.7".freeze

  s.specification_version = 4

  s.add_runtime_dependency(%q<tty-prompt>.freeze, [">= 0".freeze])
  s.add_development_dependency(%q<rspec>.freeze, ["~> 3.5.0".freeze])
  s.add_development_dependency(%q<rdoc>.freeze, ["~> 3.12".freeze])
  s.add_development_dependency(%q<bundler>.freeze, [">= 1.0".freeze])
  s.add_development_dependency(%q<juwelier>.freeze, ["~> 2.1.0".freeze])
  s.add_development_dependency(%q<simplecov>.freeze, [">= 0".freeze])
  s.add_development_dependency(%q<e2mmap>.freeze, ["~> 0.1.0".freeze])
  s.add_development_dependency(%q<puts_debuggerer>.freeze, [">= 0".freeze])
end
