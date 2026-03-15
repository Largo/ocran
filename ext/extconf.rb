gem_root = File.expand_path('..', __dir__)
src_dir  = File.join(gem_root, 'src')
stub_dir = File.join(gem_root, 'share', 'ocran')

if Gem.win_platform?
  system('ridk', 'exec', 'make', '-C', src_dir, 'install') ||
    system('make', '-C', src_dir, 'install') ||
    abort('Build failed')
else
  system('make', '-C', src_dir, 'install') || abort('Build failed')
  File.chmod(0755, File.join(stub_dir, 'stub'))
end

# Satisfy RubyGems' expectation that extconf.rb produces a Makefile
File.write('Makefile', "all:\ninstall:\nclean:\n")
