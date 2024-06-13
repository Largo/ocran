require "tempfile"
require_relative "windows_command_escaping"
require_relative "inno_setup_script_builder"
require_relative "launcher_batch_builder"

module Ocran
  class InnoSetupBuilder
    include WindowsCommandEscaping

    def files
      @iss.files
    end

    def initialize(path, inno_setup_script, chdir_before: nil, icon_path: nil, title: nil, &b)
      @path = path

      if icon_path
        copy_file(icon_path, icon_path.basename)
      end
      @iss = InnoSetupScriptBuilder.new(inno_setup_script)
      @launcher = LauncherBatchBuilder.new(chdir_before: chdir_before, title: title)

      yield(self)

      @launcher.build
      Ocran.verbose_msg "### Application launcher batch file ###"
      Ocran.verbose_msg File.read(@launcher)

      copy_file(@launcher.to_path, "launcher.bat")

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
      Ocran.verbose_msg "m #{target}"
    end

    def copy_file(source, target)
      @iss.copy_file(source, target)
      Ocran.verbose_msg "a #{target}"
    end

    alias copy copy_file
    alias cp copy_file

    def touch(target)
      @iss.touch(target)
    end

    # Specifies the final application script to be launched, which can be called
    # from any position in the data stream. It cannot be specified more than once.
    def set_script(image, script, *argv)
      if @script_info
        raise "Script is already set"
      end
      @script_info = true

      @launcher.set_script(image, script, *argv)
      extra_argc = argv.map { |arg| quote_and_escape(arg) }.join(" ")
      Ocran.verbose_msg "p #{image} #{script} #{show_path extra_argc}"
    end

    def setenv(name, value)
      @launcher.setenv(name, value)
      Ocran.verbose_msg "e #{name} #{show_path value}"
    end

    def show_path(x)
      x.to_s.gsub(TEMPDIR_ROOT.to_s, "{app}")
    end
    private :show_path
  end
end
