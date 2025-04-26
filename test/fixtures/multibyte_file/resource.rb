Dir.chdir File.dirname(__FILE__)

expected_name = "äあ💎.txt"
expected_content = "Hello Multibyte File!\n"

actual_name = Dir.entries(".").find { |f| f.bytes == expected_name.bytes }
raise "File not found" unless actual_name

content = File.read(actual_name)
raise "File content mismatch" unless content == expected_content
