require "tempfile"
require_relative "windows_command_escaping"
require_relative "launcher_batch_builder"

module Ocran
  class InnoSetupBuilder

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

      if icon_path
        copy_file(icon_path, icon_path.basename)
      end

      @launcher = LauncherBatchBuilder.new(chdir_before: @chdir_before, title: title)

      yield(self)

      @launcher.build
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
