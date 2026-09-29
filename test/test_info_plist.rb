# frozen_string_literal: true
require "minitest/autorun"
require_relative "../lib/ocran/direction"

# Unit tests for the Info.plist of --macosx-bundle builds.
class TestInfoPlist < Minitest::Test
  def strings(plist)
    plist.scan(%r{<string>(.*?)</string>}).flatten
  end

  # Values went into the XML unescaped, so an app named "R&D" produced a
  # property list macOS could not read.
  def test_values_are_xml_escaped
    plist = Ocran::Direction.info_plist(%q{R&D <"it's">}, "com.example.r&d")
    assert_includes strings(plist), "R&amp;D &lt;&quot;it&apos;s&quot;&gt;"
    assert_includes strings(plist), "com.example.r&amp;d"
    refute_match(/&(?!amp;|lt;|gt;|quot;|apos;)/, plist)
  end

  def test_icon_entry
    assert_includes Ocran::Direction.info_plist("app", "id", icon: true), "<key>CFBundleIconFile</key>"
    refute_includes Ocran::Direction.info_plist("app", "id"), "CFBundleIconFile"
  end
end
