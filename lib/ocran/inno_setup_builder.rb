module Ocran
  class InnoSetupBuilder
    attr_reader :files

    def initialize(path, chdir_before: nil, icon_path: nil, inno_setup_script: nil, &b)
      @executable = path.sub_ext(".bat")
      @chdir_before = chdir_before
      @inno_setup_script = inno_setup_script
      @dirs = {}
      @files = {}
      @envs = {}

      if icon_path
        create_file(icon_path, icon_path.basename)
      end

      yield(self)

      Ocran.verbose_msg "### INNOSETUP SCRIPT ###"
      iss = build_inno_setup_script
      Ocran.verbose_msg File.read(iss.path)

      Ocran.msg "Running InnoSetup compiler ISCC"
      compile(iss.path)
    end

    def mkdir(path)
      return if path.to_s == "."

      key = path.to_s.downcase
      return if @dirs[key]

      @dirs[key] = path
      Ocran.verbose_msg "m #{path}"
    end

    def create_file(src, tgt)
      unless src.exist?
        raise "The file does not exist (#{src})"
      end

      key = tgt.to_s.downcase
      return if @files[key]

      @files[key] = [tgt, src]
      Ocran.verbose_msg "a #{tgt}"
    end

    # Specifies the final application script to be launched, which can be called
    # from any position in the data stream. It cannot be specified more than once.
    def set_script(image, script, *argv)
      if @script_info
        raise "Script is already set"
      end

      @script_info = [image, script, *argv]

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

    def escape_double_quotes(s)
      s.to_s.gsub('"', '""')
    end
    private :escape_double_quotes

    def quote_and_escape(s)
      "\"#{escape_double_quotes(s)}\""
    end
    private :quote_and_escape

    INST_DIR = "%~dp0"

    def replace_inst_dir_placeholder(s)
      s.gsub(/#{Regexp.escape(TEMPDIR_ROOT.to_s)}[\/\\]/, INST_DIR)
    end
    private :replace_inst_dir_placeholder

    def build_launch_batch
      require "tempfile"
      Tempfile.open(["", ".iss"], Dir.pwd) do |f|
        f.puts "@echo off"
        @envs.each { |name, val| f.puts "set \"#{name}=#{replace_inst_dir_placeholder(val)}\"" }

        image, script, *argv = @script_info.map(&:to_s)
        args = ["start"]
        args << quote_and_escape(@executable.sub_ext(""))
        args << "/d #{quote_and_escape("#{INST_DIR}#{SRCDIR}")}" if @chdir_before
        args << quote_and_escape("#{INST_DIR}#{image}")
        args << quote_and_escape("#{INST_DIR}#{script}")
        args += argv.map { |arg| quote_and_escape(replace_inst_dir_placeholder(arg)) }
        args << "%*" # Forward batch file arguments to the command with `%*`
        f.puts args.join(" ")
        f
      end
    end
    private :build_launch_batch

    def build_dirs_section_item(name:)
      "Name: #{quote_and_escape(name)};"
    end
    private :build_dirs_section_item

    def build_files_section_item(source:, dest_dir:, dest_name: nil)
      s = ["Source: #{quote_and_escape(source)};"]
      s << "DestDir: #{quote_and_escape(dest_dir)};"
      s << "DestName: #{quote_and_escape(dest_name)};" if dest_name
      s.join(" ")
    end
    private :build_files_section_item

    def build_inno_setup_script
      @launcher = build_launch_batch
      Ocran.verbose_msg File.read(@launcher.path)

      require "tempfile"
      Tempfile.open(["", ".iss"], Dir.pwd) do |f|
        f.puts File.read(@inno_setup_script)
        f.puts
        f.puts "[Dirs]"
        @dirs.each_value do |dir|
          f.puts build_dirs_section_item(name: "{app}\\#{dir}")
        end
        f.puts
        f.puts "[Files]"
        f.puts build_files_section_item(source: @launcher.path, dest_dir: "{app}", dest_name: @executable)
        @files.each_value do |tgt, src|
          dest_dir = Ocran::Pathname(tgt).dirname.to_native
          f.puts build_files_section_item(source: src, dest_dir: "{app}\\#{dest_dir}")
        end
        @iss = f
      end
    end
    private :build_inno_setup_script

    def compile(iss_path)
      iscc_cmd = ["ISCC"]
      iscc_cmd << "/Q" unless Ocran.verbose
      iscc_cmd << iss_path
      unless system(*iscc_cmd)
        case $?.exitstatus
        when 0 then raise "ISCC reported success, but system reported error?"
        when 1 then raise "ISCC reports invalid command line parameters"
        when 2 then raise "ISCC reports that compilation failed"
        else raise "ISCC failed to run. Is the InnoSetup directory in your PATH?"
        end
      end
    end
    private :compile
  end
end
