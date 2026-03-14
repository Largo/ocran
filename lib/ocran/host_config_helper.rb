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

    def libruby_so
      name = RbConfig::CONFIG["LIBRUBY_SO"]
      return nil if name.nil? || name.empty?
      @libruby_so ||= Pathname.new(name)
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
