# frozen_string_literal: true

module Ocran
  module BuilderOpsLogger
    def mkdir(target)
      puts "mkdir #{target}"
      super
    end

    def cp(source, target)
      puts "cp #{source} #{target}"
      super
    end

    def touch(target)
      puts "touch #{target}"
      super
    end

    def exec(image, script, *argv)
      args = argv.map { |s| replace_placeholder(s) }.join(" ")
      puts "exec #{image} #{script} #{args}"
      super
    end

    def export(name, value)
      puts "export #{name}=#{replace_placeholder(value)}"
      super
    end

    def replace_placeholder(s)
      s.to_s.gsub(TEMPDIR_ROOT.to_s, "<tempdir>")
    end
    private :replace_placeholder
  end
end
