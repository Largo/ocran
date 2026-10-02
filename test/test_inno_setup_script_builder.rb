# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/ocran/inno_setup_script_builder"

# Unit tests for the [Dirs]/[Files] sections Ocran::InnoSetupScriptBuilder
# appends to the user's Inno Setup script. Compiling them needs ISCC; the
# text is checked everywhere.
class TestInnoSetupScriptBuilder < Minitest::Test
  def build_script
    Dir.mktmpdir do |dir|
      # The builder writes its script to the working directory, like ISCC.
      Dir.chdir(dir) do
        source = File.join(dir, "a{b}.rb")
        File.write(source, "")
        plain = File.join(dir, "plain.rb")
        File.write(plain, "")
        builder = Ocran::InnoSetupScriptBuilder.new(nil)
        yield builder, source, plain
        File.read(builder.build).lines(chomp: true)
      end
    end
  end

  # "{" starts an Inno Setup constant in Name, DestDir and DestName; a
  # packed path containing one ("lib/{x}") broke the installer build.
  def test_braces_in_destinations_are_escaped
    source = nil
    lines = build_script do |builder, src, plain|
      source = src
      builder.mkdir("data/{y}")
      builder.cp(src, "lib/{x}/a{b}.rb")
      builder.cp(plain, "lib/plain.rb")
    end

    assert_includes lines, 'Name: "{app}/data/{{y}";'
    assert_includes lines, %(Source: "#{source}"; DestDir: "{app}/lib/{{x}"; DestName: "a{{b}.rb";)
    assert(lines.any? { |line| line.end_with?('plain.rb"; DestDir: "{app}/lib";') })
  end
end
