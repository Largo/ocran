# frozen_string_literal: true

source "https://rubygems.org"

gem "rake", "~> 13.0"

gem "minitest", "~> 6.0"

gem "fiddle", "~> 1.0"
# The GUI toolkits the GUI packaging tests use. CI jobs that test nothing
# GUI leave them out with BUNDLE_WITHOUT=gui: fxruby compiles against the
# FOX headers, which only the jobs that test it install.
group :gui do
  gem "glimmer-dsl-libui"
  # fxruby needs the FOX toolkit, which has no Visual C++ build
  gem "fxruby" unless RUBY_PLATFORM.include?("mswin")
end

gem 'logger'
gem 'csv'
gem 'matrix'