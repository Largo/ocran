# rake-tui
[![Gem Version](https://badge.fury.io/rb/rake-tui.svg)](https://badge.fury.io/rb/rake-tui)

[Rake](https://github.com/ruby/rake) Text-Based User Interface

![Rake TUI Demo](rake-tui-demo.gif)

Other TUI gems you may be interested in:
- [rvm-tui](https://github.com/AndyObtiva/rvm-tui)

## Pre-requisites

- [Ruby](https://www.ruby-lang.org/en/)

## Setup Instructions

### Vanilla Ruby

```
gem install rake-tui
```

### Bundler

```ruby
gem 'rake-tui', require: false
```

### [RVM](https://rvm.io/)

```
rvm @global do gem install rake-tui
```

## Usage

Simply run this command:

```
rakeui
```

Or one of the aliases:

```
rake-ui
raketui
rake-tui
```

### [JRuby](https://www.jruby.org/)

If you are using [RVM](https://rvm.io/), then `rake-tui` works in [JRuby](https://www.jruby.org/) too.

Otherwise, simply run this command instead:

```
jrakeui
```

Or one of the aliases:

```
jrake-ui
jraketui
jrake-tui
```

## API

To use [rake-tui](https://rubygems.org/gems/rake-tui) as part of a Ruby app, require the [rake-tui](https://rubygems.org/gems/rake-tui) gem once at the top of your code:

```ruby
require 'rake-tui'
```

Afterwards, simply invoke the `Rake::TUI.run` method wherever you need to display the TUI to the user:

```ruby
Rake::TUI.run
```

If you'd rather specify or limit the tasks shown, then pass the tasks to the constructor before running:

```ruby
Rake::TUI.new(tasks).run
```

If you want to make that the default, then set the singleton instance:

```ruby
Rake::TUI.instance(Rake::TUI.new(tasks))
Rake::TUI.run # this now displays the specified task list
```

## Options

### `branding_header`

The default branding header looks like this (from `Rake::TUI::BRANDING_HEADER_DEFAULT`):

```
== rake-tui version 0.2.3 ==
```

It may be customized by passing in the `branding_header` option (removed when set to `nil`).

Example:

```ruby
Rake::TUI.run(branding_header: '== Glimmer (Ruby Desktop Development GUI Library) ==')
```

Output:

```
== Glimmer (Ruby Desktop Development GUI Library) ==
```

### `prompt_question`

The prompt question is the text that shows up before the help message and looks like this (from `Rake::TUI::PROMPT_QUESTION_DEFAULT`):

```
Choose a Rake task:
```

It may be customized by passing in the `prompt_question` option:

Example:

```ruby
Rake::TUI.run(prompt_question: 'Select a Glimmer task:')
```

Output:

```
Select a Glimmer task:  (Press ↑/↓ arrow to move, Enter to select and letters to filter)
```

### `task_formatter` block

The task formatter (default: `Rake::TUI::TASK_FORMATTER_DEFAULT`) is responsible for formatting
tasks into task lines presented as choices to the user.

It receives `task` and `tasks` list as options.

For example, by default, it prints the same standard output you see from running `rake -T`:

```
  rake build               # Build gem into pkg/
  rake clean               # Remove any temporary products
  rake clobber             # Remove any generated files
  rake clobber_rdoc        # Remove RDoc HTML files
  rake console[script]     # Start IRB with all runtime dependencies loaded
  rake gemcutter:release   # Release gem to Gemcutter
  rake gemspec             # Generate and validate gemspec
  rake gemspec:debug       # Display the gemspec for debugging purposes, as juwelier knows it (not from the filesystem)
  rake gemspec:generate    # Regenerate the gemspec on the filesystem
‣ rake gemspec:release     # Regenerate and validate gemspec, and then commits and pushes to git
  rake gemspec:validate    # Validates the gemspec on the filesystem
  rake git:release         # Tag and push release to git
  rake install             # Build and install gem using `gem install`
  rake rdoc                # Build RDoc HTML files
  rake release             # Release gem
  rake rerdoc              # Rebuild RDoc HTML files
  rake simplecov           # Code coverage detail
  rake spec                # Run RSpec code examples
  rake version             # Displays the current version
  rake version:bump:major  # Bump the major version by 1
  rake version:bump:minor  # Bump the a minor version by 1
  rake version:bump:patch  # Bump the patch version by 1
  rake version:write       # Writes out an explicit version
```

However, it can be customized by passing in a `task_formatter` block.

Example:

```ruby
Rake::TUI.new.run { |task, tasks| task.name_with_args }
```

Output:

```
  build
  clean
  clobber
  clobber_rdoc
  console[script]
  gemcutter:release
  gemspec
  gemspec:debug
  gemspec:generate
  gemspec:release
  gemspec:validate
  git:release
  install
  rdoc
‣ release
  rerdoc
  simplecov
  spec
  version
  version:bump:major
  version:bump:minor
  version:bump:patch
  version:write
```

## TODO

[TODO.md](TODO.md)

## Change Log

[CHANGELOG.md](CHANGELOG.md)

## Contributing to rake-tui

-   Check out the latest master to make sure the feature hasn't been
    implemented or the bug hasn't been fixed yet.
-   Check out the issue tracker to make sure someone already hasn't
    requested it and/or contributed it.
-   Fork the project.
-   Start a feature/bugfix branch.
-   Commit and push until you are happy with your contribution.
-   Make sure to add tests for it. This is important so I don't break it
    in a future version unintentionally.
-   Please try not to mess with the Rakefile, version, or history. If
    you want to have your own version, or is otherwise necessary, that
    is fine, but please isolate to its own commit so I can cherry-pick
    around it.

## Copyright

[MIT](LICENSE.txt)

Copyright (c) 2020 Andy Maleh.
