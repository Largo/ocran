require "tempfile"
require_relative "windows_command_escaping"
require_relative "inno_setup_script_builder"
require_relative "launcher_batch_builder"

module Ocran
  class InnoSetupBuilder
    include WindowsCommandEscaping

    def initialize(path, inno_setup_script, chdir_before: nil, icon_path: nil, title: nil, &b)
      @path = path
      @iss = InnoSetupScriptBuilder.new(inno_setup_script)
      @launcher = LauncherBatchBuilder.new(chdir_before: chdir_before, title: title)

      if icon_path
        cp(icon_path, File.basename(icon_path))
      end

      yield(self)

      @launcher.build
      Ocran.verbose_msg "### Application launcher batch file ###"
      Ocran.verbose_msg File.read(@launcher)

      cp(@launcher.to_path, "launcher.bat")

      @iss.build
      Ocran.verbose_msg "### INNO SETUP SCRIPT ###"
      Ocran.verbose_msg File.read(@iss)

      Ocran.msg "Running Inno Setup Command-Line compiler (ISCC)"
      compile
    end

    def compile
      iscc_cmd = ["ISCC"]
      iscc_cmd << "/Q" unless Ocran.verbose
      iscc_cmd << @iss.to_path
      unless system(*iscc_cmd)
        case $?.exitstatus
        when 0 then raise "ISCC reported success, but system reported error?"
        when 1 then raise "ISCC reports invalid command line parameters"
        when 2 then raise "ISCC reports that compilation failed"
        else raise "ISCC failed to run. Is the InnoSetup directory in your PATH?"
        end
      end
    end

    def mkdir(target)
      @iss.mkdir(target)
    end

    def cp(source, target)
      @iss.cp(source, target)
    end

    def touch(target)
      @iss.touch(target)
    end

    # Specifies the final application script to be launched, which can be called
    # from any position in the data stream. It cannot be specified more than once.
    def exec(image, script, *argv)
      if @script_info
        raise "Script is already set"
      end
      @script_info = true

      @launcher.exec(image, script, *argv)
    end

    def export(name, value)
      @launcher.export(name, value)
    end
  end
end
