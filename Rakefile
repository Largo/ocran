require "rubygems"

# Building the stubs needs only a C compiler, none of the development gems
# in the Gemfile, so a run of nothing but the stub tasks leaves Bundler and
# Minitest out: `rake build` then works in a checkout whose bundle is not
# installed, such as a Bundler git source. Anything else, the tests above
# all, runs under the bundle as before.
STUB_TASKS = %w[build build_stub clean].freeze
requested = Rake.application.top_level_tasks
unless requested.any? && (requested - STUB_TASKS).empty?
  require 'bundler/setup'
  require "minitest/test_task"

  # rake test: runs test/**/test_*.rb. The gems themselves are built from
  # ocran.gemspec and ocran-source.gemspec (see .github/workflows/gem-release.yml).
  Minitest::TestTask.create
end

task :default => :test

WINDOWS = Gem.win_platform?
# mswin Ruby (built with Visual C++) has no MSYS2 devkit: build the stubs
# with nmake from a Visual Studio developer prompt instead.
MSWIN = RUBY_PLATFORM.include?("mswin")
STUB_DIR   = "share/ocran"
BUILD_DIR  = "src"

if WINDOWS
  STUB_NAMES = %w[stub stubw]
  STUB_EXE_EXT = ".exe"
else
  STUB_NAMES = %w[stub]
  STUB_EXE_EXT = ""
end

desc "Builds all necessary artifacts (currently stubs)"
task :build => :build_stub

task :build_stub do
  if MSWIN
    Dir.chdir(BUILD_DIR) { sh "nmake -nologo -f Makefile.mswin" }
    STUB_NAMES.each do |name|
      cp "#{BUILD_DIR}/#{name}.exe", "#{STUB_DIR}/#{name}.exe"
    end
  elsif WINDOWS
    sh "ridk exec make -C #{BUILD_DIR}"
    STUB_NAMES.each do |name|
      cp "#{BUILD_DIR}/#{name}.exe", "#{STUB_DIR}/#{name}.exe"
    end
  else
    sh "make -C #{BUILD_DIR}"
    cp "#{BUILD_DIR}/stub", "#{STUB_DIR}/stub"
    File.chmod(0755, "#{STUB_DIR}/stub")
  end
end

STUB_NAMES.each do |name|
  stub_path = "#{STUB_DIR}/#{name}#{STUB_EXE_EXT}"
  file stub_path => :build_stub
end

task :clean do
  rm_f STUB_NAMES.map { |name| "#{STUB_DIR}/#{name}#{STUB_EXE_EXT}" }
  if MSWIN
    Dir.chdir(BUILD_DIR) { sh "nmake -nologo -f Makefile.mswin clean" }
  elsif WINDOWS
    sh "ridk exec make -C #{BUILD_DIR} clean"
  else
    sh "make -C #{BUILD_DIR} clean"
  end
end

task :test_single, [:test_name] do |t, args|
  if args[:test_name].nil?
    puts "You must provide a test name. e.g., rake test_single[YourTestClassName]"
  else
    sh "ruby #{File.join("test", "test_ocra.rb")} -n test_#{args[:test_name]}"
  end
end
