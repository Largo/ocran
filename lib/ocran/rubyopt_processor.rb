# frozen_string_literal: true

module Ocran
  # Parses the RUBYOPT environment variable the way Ruby itself does
  # (whitespace-separated words; -I and -r may take their argument either
  # attached or as the following word) and translates -I/-r entries that
  # refer to absolute build-machine paths into their locations inside the
  # packed application.
  #
  # Translated entries cannot simply be rewritten inside RUBYOPT: the
  # extraction directory is only known at runtime and may contain spaces,
  # and Ruby does not support any form of quoting in RUBYOPT. The
  # translated entries are therefore removed from RUBYOPT and returned
  # separately so that the build can apply them through a generated
  # launcher script instead. See GitHub issue #20.
  class RubyoptProcessor
    # -r entries whose feature path matches this pattern are always removed.
    # When building under `bundle exec` (Ruby 3.2+), Bundler injects
    # `-r<absolute path>/bundler/setup` into RUBYOPT; requiring it inside
    # the packed application would make Bundler look for the build
    # machine's Gemfile, so it must not survive into the executable.
    BUNDLER_SETUP_PATTERN = %r{/bundler/setup\z}

    # rubyopt:    the RUBYOPT string with all translated/removed entries
    #             stripped; safe to bake into the executable as-is.
    # load_paths: packed locations (relative to the extraction root) for
    #             translated -I entries, in the order given.
    # requires:   packed locations (relative to the extraction root) for
    #             translated -r entries, in the order given.
    # dropped:    -I/-r entries with absolute paths that are not part of
    #             the package; they cannot work at runtime and were removed.
    Result = Struct.new(:rubyopt, :load_paths, :requires, :dropped) do
      def translated?
        !load_paths.empty? || !requires.empty?
      end
    end

    def initialize(rubyopt)
      @rubyopt = rubyopt.to_s
    end

    # Translates absolute -I/-r paths. For each absolute path the block is
    # called with the path (String) and must return the corresponding
    # location inside the packed application (relative to the extraction
    # root), or nil when the path is not part of the package.
    def translate
      remaining, load_paths, requires, dropped = [], [], [], []

      words = @rubyopt.split
      until words.empty?
        word = words.shift
        case word
        when /\A-I(.*)\z/m
          arg = $1.empty? ? words.shift : $1
          next if arg.nil?

          kept = []
          arg.split(File::PATH_SEPARATOR).each do |dir|
            next if dir.empty?

            if File.absolute_path?(dir)
              if (packed = yield(dir))
                load_paths << packed
              else
                dropped << "-I#{dir}"
              end
            else
              kept << dir
            end
          end
          remaining << "-I#{kept.join(File::PATH_SEPARATOR)}" unless kept.empty?
        when /\A-r(.*)\z/m
          feature = $1.empty? ? words.shift : $1
          next if feature.nil?

          if feature.match?(BUNDLER_SETUP_PATTERN)
            # Silently stripped, see BUNDLER_SETUP_PATTERN above.
          elsif File.absolute_path?(feature)
            if (packed = yield(feature))
              requires << packed
            else
              dropped << "-r#{feature}"
            end
          else
            remaining << "-r#{feature}"
          end
        else
          remaining << word
        end
      end

      Result.new(remaining.join(" "), load_paths, requires, dropped)
    end
  end
end
