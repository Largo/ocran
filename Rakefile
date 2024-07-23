require "rubygems"
require 'bundler/setup'
require "hoe"

Hoe.plugin :minitest

spec = Hoe.spec "ocran" do
  developer "Lars Christensen", "larsch@belunktum.dk"
  developer "Andi Idogawa", "andi@idogawa.com"
  license "MIT"
end

spec.urls.each { |key, url| url.chomp! }

task :build_stub do
  sh "ridk exec make -C src"
  cp "src/stub.exe", "share/ocran/stub.exe"
  cp "src/stubw.exe", "share/ocran/stubw.exe"
  cp "src/edicon.exe", "share/ocran/edicon.exe"
end

file "share/ocran/stub.exe" => :build_stub
file "share/ocran/stubw.exe" => :build_stub
file "share/ocran/edicon.exe" => :build_stub

task :test => :build_stub

task :clean do
  rm_f Dir["{bin,samples}/*.exe"]
  rm_f Dir["share/ocran/{stub,stubw,edicon}.exe"]
  sh "ridk exec make -C src clean"
end

task :release_docs => :redocs do
  sh "pscp -r doc/* larsch@ocran.rubyforge.org:/var/www/gforge-projects/ocran"
end

task :test_single, [:test_name] do |t, args|
  if args[:test_name].nil?
    puts "You must provide a test name. e.g., rake test_single[YourTestClassName]"
  else
    sh "ruby #{File.join("test", "test_ocra.rb")} -n test_#{args[:test_name]}"
  end
end
