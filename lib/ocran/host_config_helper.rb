require "rbconfig"

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

    def libruby_so
      @libruby_so ||= Pathname.new(RbConfig::CONFIG["LIBRUBY_SO"])
    end

    def exe_extname
      RbConfig::CONFIG["EXEEXT"] || ".exe"
    end

    def rubyw_exe
      @rubyw_exe ||= (RbConfig::CONFIG["rubyw_install_name"] || "rubyw") + exe_extname
    end

    def ruby_exe
      @ruby_exe ||= (RbConfig::CONFIG["ruby_install_name"] || "ruby") + exe_extname
    end
  end
end
