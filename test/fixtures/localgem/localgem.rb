begin
  require 'mylocal'
rescue LoadError
  # During the OCRAN dependency run the local development gem is not yet
  # activatable via RubyGems; set it up through Bundler like a developer
  # would. In the packaged app the gem lives in the bundled GEM_HOME, so
  # the plain require above succeeds and Bundler is never needed.
  require 'bundler/setup'
  require 'mylocal'
end

exit 1 unless Mylocal.hello == "hello from mylocal"
