# frozen_string_literal: true

module Ocran
  # Locates the ahead-of-time compilers behind --spinel and --roundhouse,
  # and words the instructions for installing whichever of them is missing.
  #
  # None of them is a gem: Spinel (https://github.com/matz/spinel) is built
  # from source and installs two commands, the compiler `spinel` and its
  # project tool `spin`; Roundhouse (https://github.com/rubys/roundhouse) is
  # a single prebuilt binary. Each is looked up in the environment variable
  # named after it (a path to the command or to the directory holding it),
  # then in PATH, then where its own install instructions put it.
  module AotToolchain
    Tool = Struct.new(:command, :env, :locations, keyword_init: true)

    TOOLS = {
      spinel: Tool.new(
        command: "spinel",
        env: "SPINEL",
        # `make install` (default PREFIX /usr/local, or PREFIX=$HOME/.local),
        # and the convenience symlink `make` leaves at the root of a checkout.
        locations: %w[~/.local/bin/spinel /usr/local/bin/spinel /opt/homebrew/bin/spinel
                      ~/spinel/spinel ~/src/spinel/spinel]
      ),
      spin: Tool.new(
        command: "spin",
        env: "SPIN",
        locations: %w[~/.local/bin/spin /usr/local/bin/spin /opt/homebrew/bin/spin
                      ~/spinel/bin/spin ~/src/spinel/bin/spin]
      ),
      roundhouse: Tool.new(
        command: "roundhouse",
        env: "ROUNDHOUSE",
        # The installer script puts it in ~/.local/bin, `cargo install` in
        # ~/.cargo/bin.
        locations: %w[~/.local/bin/roundhouse ~/.cargo/bin/roundhouse /usr/local/bin/roundhouse
                      /opt/homebrew/bin/roundhouse]
      ),
    }.freeze

    SPINEL_URL = "https://github.com/matz/spinel"
    ROUNDHOUSE_URL = "https://github.com/rubys/roundhouse"

    module_function

    # Absolute path of the given tool (:spinel, :spin or :roundhouse), or
    # nil when it is not installed anywhere OCRAN knows to look. Raises when
    # the tool's environment variable names something that is not it, since
    # silently falling back to another copy would hide the typo.
    def find(name, env = ENV)
      tool = TOOLS.fetch(name)

      if (specified = env[tool.env]) && !specified.empty?
        found = executable_in(File.expand_path(specified), tool.command)
        return found if found

        raise "#{tool.env}=#{specified} does not name the #{tool.command} command " \
              "(expected the executable itself or the directory containing it)"
      end

      search_path(tool.command, env) ||
        tool.locations.lazy.flat_map { |pattern| Dir.glob(File.expand_path(pattern)) }
                          .find { |path| executable?(path) }
    end

    # Hash of name => path for the given tools, with nil for missing ones.
    def find_all(names, env = ENV)
      names.to_h { |name| [name, find(name, env)] }
    end

    # The first line `<tool> --version` prints, or nil if it cannot be run.
    def version(path)
      out = IO.popen([path, "--version"], err: [:child, :out], &:read)
      line = out.to_s.lines.first&.strip
      $?.success? && line && !line.empty? ? line : nil
    rescue SystemCallError
      nil
    end

    # Instructions for installing the given missing tools, as one string.
    def install_instructions(missing)
      lines = []

      if Gem.win_platform?
        lines << "Spinel does not build natively on Windows yet (Roundhouse's Windows build is untested)."
        lines << "Until it does, run OCRAN inside WSL (https://learn.microsoft.com/windows/wsl/install),"
        lines << "where both work as on Linux; the result is then a Linux binary. Once they support"
        lines << "Windows, installing them there is all this option needs."
        lines << ""
      end

      if missing.include?(:spinel) || missing.include?(:spin)
        lines << "Spinel (provides `spinel` and `spin`) is built from source, it is not a gem:"
        lines << ""
        lines << "    git clone #{SPINEL_URL}"
        lines << "    cd spinel"
        lines << "    make deps                       # fetch libprism (one-time)"
        lines << "    make"
        lines << "    make install PREFIX=$HOME/.local  # or: sudo make install"
        lines << ""
        lines << "It needs a C compiler (gcc or clang) and make. Release archives that build"
        lines << "offline are on #{SPINEL_URL}/releases."
        lines << ""
      end

      if missing.include?(:roundhouse)
        lines << "Roundhouse ships as a single binary:"
        lines << ""
        lines << "    curl --proto '=https' --tlsv1.2 -LsSf \\"
        lines << "      #{ROUNDHOUSE_URL}/releases/latest/download/roundhouse-installer.sh | sh"
        lines << ""
        lines << "or, with a Rust toolchain:"
        lines << ""
        lines << "    cargo install --git #{ROUNDHOUSE_URL} --bin roundhouse"
        lines << ""
        lines << "The Rails app compiled through it links SQLite and jemalloc, so their"
        lines << "development headers are needed as well (Debian/Ubuntu:"
        lines << "`sudo apt install libsqlite3-dev libjemalloc-dev`, macOS: `brew install sqlite jemalloc`)."
        lines << ""
      end

      env_vars = missing.map { |name| TOOLS.fetch(name).env }
      lines << "OCRAN looks in PATH and the usual install locations; set #{env_vars.join(" / ")} " \
               "to point it at a copy installed elsewhere."
      lines.join("\n")
    end

    def search_path(command, env = ENV)
      exts = Gem.win_platform? ? env.fetch("PATHEXT", ".EXE;.BAT;.CMD").split(";") : [""]
      env.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?

        exts.each do |ext|
          path = File.join(File.expand_path(dir), "#{command}#{ext}")
          return path if executable?(path)
        end
      end
      nil
    end

    def executable_in(path, command)
      return path if executable?(path)
      return nil unless File.directory?(path)

      names = Gem.win_platform? ? ["#{command}.exe", command] : [command]
      [path, File.join(path, "bin")].product(names).map { |dir, name| File.join(dir, name) }
                                    .find { |p| executable?(p) }
    end

    def executable?(path)
      File.file?(path) && File.executable?(path)
    end
  end
end
