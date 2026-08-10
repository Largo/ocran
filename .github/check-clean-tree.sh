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
# Untracked files are ignored on purpose: the builds leave stubs and packed
# executables behind. So are vendor/ and .bundle/, which are checked in but
# describe the machine rather than the project: `bundle install` rewrites the
# vendored bundle (shebangs and line endings differ per platform) and
# ruby/setup-ruby writes `deployment: true` into the config, both before
# anything of ours has run.
set -eu

dirty=$(git status --porcelain --untracked-files=no \
        -- . ':(exclude)vendor' ':(exclude).bundle')
if [ -n "$dirty" ]; then
    echo "::error::the test run modified files under version control"
    echo "$dirty"
    git diff --stat -- . ':(exclude)vendor' ':(exclude).bundle'
    exit 1
fi

echo "working tree clean"
