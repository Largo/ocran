if Gem.win_platform?
  Dir.chdir ENV["SystemRoot"]
else
  Dir.chdir "/"
end
