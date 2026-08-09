require "mylib"
File.open("output.txt", "w") do |f|
  f.write "preloaded=#{$preloaded.inspect};mylib=#{Mylib.hello}"
end
