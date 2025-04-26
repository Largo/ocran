Dir.chdir File.dirname(__FILE__)

dir_expected = "äあ💎"
file_expected = "äあ💎.txt"
expected_content = "Hello Multibyte File!\n"

dir_actual = Dir.entries(".").find { |d| File.directory?(d) && d.bytes == dir_expected.bytes }
raise "Directory not found" unless dir_actual

file_actual = Dir.entries(dir_actual).find { |f| f.bytes == file_expected.bytes }
raise "File not found in directory" unless file_actual

content = File.read(File.join(dir_actual, file_actual))
raise "File content mismatch" unless content == expected_content
