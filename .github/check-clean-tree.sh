#!/bin/sh
# Fails when the test run modified a file under version control.
#
# The tests run Bundler against fixture Gemfiles. A Bundler that has been
# pointed at the wrong lockfile - `bundle exec` exports BUNDLE_LOCKFILE, and
# children inherit it - rewrites OCRAN's own Gemfile.lock with a fixture's
# dependencies. The test suite stays green; what dies is the next step that
# runs `bundle exec`, with a frozen-mode error that names neither the test
# that did it nor the fact that a test did it at all.
#
# Untracked files are ignored on purpose: `bundle install` populates
# vendor/bundle, and builds leave stubs and packed executables behind.
set -eu

dirty=$(git status --porcelain --untracked-files=no)
if [ -n "$dirty" ]; then
    echo "::error::the test run modified files under version control"
    echo "$dirty"
    git diff --stat
    exit 1
fi

echo "working tree clean"
