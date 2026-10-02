# The application of the README's GitHub Actions example: its gems come from
# a Gemfile and are required plainly, without bundler/setup
# (.github/workflows/test-readme-actions.yml, github issue #61).
require "rainbow"

puts Rainbow("readme_actions: rainbow loaded").green
