# A plain require, no bundler/setup: the gem is installed only into the
# bundle's configured path (vendor/bundle), as ruby/setup-ruby's
# `bundler-cache: true` leaves it (github issue #61).
require 'vendoredgem'

exit 1 unless Vendoredgem.hello == "hello from vendoredgem"
