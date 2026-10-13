require "rbconfig"
require "pathname"

module Ocran
  # Variables describing the host's build environment.
  module HostConfigHelper
    module_function

    def exec_prefix
      @exec_prefix ||= Pathname.new(RbConfig::CONFIG["exec_prefix"])
    end

    def sitelibdir
      @sitelibdir ||= Pathname.new(RbConfig::CONFIG["sitelibdir"])
    end

    def bindir
      @bindir ||= Pathname.new(RbConfig::CONFIG["bindir"])
    end

    def libdir
      @libdir ||= Pathname.new(RbConfig::CONFIG["libdir"])
    end

    # True when the interpreter links against a shared libruby that has to
    # be packed next to it. A Ruby configured without --enable-shared still
    # reports LIBRUBY_SO (e.g. "libruby.so.4.0.6") although only
    # libruby-static.a is installed and the interpreter is self-contained.
    def shared_libruby?
      RbConfig::CONFIG["ENABLE_SHARED"] != "no"
    end

    def libruby_so
      return nil unless shared_libruby?
      name = RbConfig::CONFIG["LIBRUBY_SO"]
      return nil if name.nil? || name.empty?
      Pathname.new(name)
    end

    def libruby_aliases
      return [] unless shared_libruby?
      aliases = RbConfig::CONFIG["LIBRUBY_ALIASES"]
      return [] if aliases.nil? || aliases.empty?
      aliases.split.map { |name| Pathname.new(name) }
    end

    def exe_extname
      RbConfig::CONFIG["EXEEXT"] || ".exe"
    end

    def rubyw_exe
      return nil unless Gem.win_platform?
      @rubyw_exe ||= (RbConfig::CONFIG["rubyw_install_name"] || "rubyw") + exe_extname
    end

    def ruby_exe
      @ruby_exe ||= (RbConfig::CONFIG["ruby_install_name"] || "ruby") + exe_extname
    end

    def all_core_dir
      RbConfig::CONFIG
          .slice("rubylibdir", "sitelibdir", "vendorlibdir")
          .values
          .map { |path| Pathname.new(path) }
    end
  end
end
