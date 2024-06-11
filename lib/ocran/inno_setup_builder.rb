require "tempfile"
require_relative "windows_command_escaping"

module Ocran
  class InnoSetupBuilder

    class AppLauncherBatchBuilder
      include WindowsCommandEscaping

      # BATCH_FILE_DIR is a parameter expansion used in Windows batch files,
      # representing the full path to the directory where the batch file resides.
      # It allows for the use of pseudo-relative paths by referencing the
      # batch file's own location without changing the working directory.
      BATCH_FILE_DIR = "%~dp0"

      # BATCH_FILE_PATH is a parameter expansion used in Windows batch files,
      # representing the full path to the batch file itself, including the file name.
      BATCH_FILE_PATH = "%~f0"

      def initialize(title, executable, script, *args, chdir_before: nil, environments: {})
        @path = Tempfile.open do |f|
          f.puts "@echo off"
          environments.each { |name, val| f.puts build_set_command(name, val) }
          f.puts build_set_command("OCRAN_EXECUTABLE", BATCH_FILE_PATH)
          f.puts build_start_command(title, executable, script, *args, chdir_before: chdir_before)
          f
        end
      end

      def to_path
        @path.to_path
      end

      def replace_inst_dir_placeholder(s)
        s.gsub(/#{Regexp.escape(TEMPDIR_ROOT.to_s)}[\/\\]/, BATCH_FILE_DIR)
      end
      private :replace_inst_dir_placeholder

      def build_set_command(name, value)
        "set \"#{name}=#{replace_inst_dir_placeholder(value)}\""
      end
      private :build_set_command

      def build_start_command(title, executable, script, *args, chdir_before: nil)
        cmd = ["start"]

        # Title for Command Prompt window title bar
        cmd << quote_and_escape(title)

        # Use /d to set the startup directory for the process,
        # which will be BATCH_FILE_DIR/SRCDIR. This path is where
        # the script is located, establishing the working directory
        # at process start.
        if chdir_before
          cmd << "/d #{quote_and_escape("#{BATCH_FILE_DIR}#{SRCDIR}")}"
        end

        cmd << quote_and_escape("#{BATCH_FILE_DIR}#{executable}")
        cmd << quote_and_escape("#{BATCH_FILE_DIR}#{script}")
        cmd += args.map { |arg| quote_and_escape(replace_inst_dir_placeholder(arg)) }

        # Forward batch file arguments to the command with `%*`
        cmd << "%*"

        cmd.join(" ")
      end
      private :build_start_command
    end

    class InnoSetupScriptBuilder
      include WindowsCommandEscaping

      def initialize(path, files: nil, dirs: [])
        @path = path
        File.open(@path, "a") do |f|
          if dirs && !dirs.empty?
            f.puts
            f.puts "[Dirs]"
            dirs.each { |obj| f.puts build_dirs_section_item(**obj) }
          end
          if files && !files.empty?
            f.puts
            f.puts "[Files]"
            files.each { |obj| f.puts build_files_section_item(**obj) }
          end
          f
        end
      end

      def to_path
        @path.respond_to?(:to_path) ? @path.to_path : @path.to_s
      end

      def build_dirs_section_item(name:)
        "Name: #{quote_and_escape(name)};"
      end
      private :build_dirs_section_item

      def build_files_section_item(source:, dest_dir:, dest_name: nil)
        s = ["Source: #{quote_and_escape(source)};"]
        s << "DestDir: #{quote_and_escape(dest_dir)};"
        if dest_name
          s << "DestName: #{quote_and_escape(dest_name)};"
        end
        s.join(" ")
      end
      private :build_files_section_item
    end

    include WindowsCommandEscaping

    attr_reader :files

    def initialize(path, inno_setup_script, chdir_before: nil, icon_path: nil, title: nil, &b)
      @path = path
      @chdir_before = chdir_before
      @inno_setup_script = inno_setup_script
      @dirs = {}
      @files = {}
      @envs = {}

      yield(self)

      if icon_path
        copy_file(icon_path, icon_path.basename)
      end

      @launcher = AppLauncherBatchBuilder.new(title,
                                              *@script_info,
                                              environments: @envs,
                                              chdir_before: @chdir_before)
      Ocran.verbose_msg "### Application launcher batch file ###"
      Ocran.verbose_msg File.read(@launcher)

      copy_file(@launcher.to_path, "launcher.bat")

      @iss = Tempfile.open(["", ".iss"], Dir.pwd) do |f|
        IO.copy_stream(@inno_setup_script, f) if @inno_setup_script
        InnoSetupScriptBuilder.new(f, files: @files.values, dirs: @dirs.values)
      end
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

    def mkdir(dir)
      return if dir.to_s == "."

      key = dir.to_s.downcase
      return if @dirs[key]

      @dirs[key] = { name: File.join("{app}", dir) }
      Ocran.verbose_msg "m #{dir}"
    end

    def copy_file(src, tgt)
      unless File.exist?(src)
        raise "The file does not exist (#{src})"
      end

      key = tgt.to_s.downcase
      return if @files[key]

      @files[key] = {
        source: src,
        dest_dir: File.join("{app}", File.dirname(tgt)),
        dest_name: File.basename(tgt)
      }
      Ocran.verbose_msg "a #{tgt}"
    end

    alias copy copy_file
    alias cp copy_file

    def touch(tgt)
      src = Pathname.new(File.expand_path("touch_placeholder", __dir__))
      copy_file(src, tgt)
    end

    # Specifies the final application script to be launched, which can be called
    # from any position in the data stream. It cannot be specified more than once.
    def set_script(image, script, *argv)
      if @script_info
        raise "Script is already set"
      end

      @script_info = [image, script, *argv].map(&:to_s)
      extra_argc = argv.map { |arg| quote_and_escape(arg) }.join(" ")
      Ocran.verbose_msg "p #{image} #{script} #{show_path extra_argc}"
    end

    def setenv(name, value)
      @envs[name.to_s] = value.to_s
      Ocran.verbose_msg "e #{name} #{show_path value}"
    end

    def show_path(x)
      x.to_s.gsub(TEMPDIR_ROOT.to_s, "{app}")
    end
    private :show_path
  end
end
