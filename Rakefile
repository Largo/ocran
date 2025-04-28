require "rubygems"
require 'bundler/setup'
require "hoe"

Hoe.plugin :minitest

Hoe.spec "ocran" do
  developer "Lars Christensen", "larsch@belunktum.dk"
  developer "Andi Idogawa", "andi@idogawa.com"
  license "MIT"
end

STUB_NAMES = %w[stub stubw edicon]
STUB_DIR   = "share/ocran"
BUILD_DIR  = "src"

task :build_stub do
  sh "ridk exec make -C #{BUILD_DIR}"
  STUB_NAMES.each do |name|
    cp "#{BUILD_DIR}/#{name}.exe", "#{STUB_DIR}/#{name}.exe"
  end
end

STUB_NAMES.each do |name|
  file "#{STUB_DIR}/#{name}.exe" => :build_stub
end

task :clean do
  rm_f Dir["{bin,samples}/*.exe"]
  rm_f STUB_NAMES.map { |name| "#{STUB_DIR}/#{name}.exe" }
  sh "ridk exec make -C #{BUILD_DIR} clean"
end

task :test_single, [:test_name] do |t, args|
  if args[:test_name].nil?
    puts "You must provide a test name. e.g., rake test_single[YourTestClassName]"
  else
    sh "ruby #{File.join("test", "test_ocra.rb")} -n test_#{args[:test_name]}"
  end
end
