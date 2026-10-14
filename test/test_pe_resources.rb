# frozen_string_literal: true
require "minitest/autorun"
require_relative "../lib/ocran/pe_resources"

# Unit tests for Ocran::PeResources, the pure-Ruby resource writer --static-runtime
# uses, on a minimal PE32+ image built here.
class TestPeResources < Minitest::Test
  # DOS header, PE header, PE32+ optional header with 16 data directories,
  # and one .text section of 0x200 bytes at RVA 0x1000.
  def minimal_pe
    pe = 0x40
    bytes = "\0".b * 0x600
    bytes[0, 2] = "MZ"
    bytes[0x3c, 4] = [pe].pack("V")
    bytes[pe, 4] = "PE\0\0".b
    bytes[pe + 4, 20] = [0x8664, 1, 0, 0, 0, 240, 0x22].pack("vvVVVvv")
    opt = pe + 24
    bytes[opt, 2] = [0x20b].pack("v")
    bytes[opt + 32, 8] = [0x1000, 0x200].pack("VV") # section, file alignment
    bytes[opt + 56, 8] = [0x2000, 0x400].pack("VV") # SizeOfImage, SizeOfHeaders
    bytes[opt + 108, 4] = [16].pack("V")
    section = opt + 240
    bytes[section, 40] = [".text", 0x200, 0x1000, 0x200, 0x400, 0, 0, 0, 0, 0x60000020].pack("a8VVVVVVvvV")
    bytes
  end

  # An .ico with two images.
  def ico
    images = ["A".b * 40, "B".b * 60]
    header = [0, 1, images.size].pack("vvv")
    offset = 6 + 16 * images.size
    images.each_with_index do |data, i|
      header << [16 * (i + 1), 16 * (i + 1), 0, 0, 1, 32, data.bytesize, offset].pack("CCCCvvVV")
      offset += data.bytesize
    end
    header + images.join
  end

  def test_resources_are_written_to_a_new_section_and_read_back
    pe = Ocran::PeResources.new(minimal_pe)
    assert_empty pe.tree
    pe.set_icon(ico)
    pe.set_version_info("VERSION".b)
    pe.set_manifest("<assembly/>")
    pe.set_strings(1 => "one", 17 => "seventeen")
    out = pe.to_bytes

    again = Ocran::PeResources.new(out)
    assert_equal pe.tree, again.tree
    assert_equal "A".b * 40, again.tree[3][1][1033]
    assert_equal "B".b * 60, again.tree[3][2][1033]
    group = again.tree[14][1][1033]
    assert_equal [0, 1, 2], group.unpack("vvv")
    assert_equal [32, 32, 60, 2], group.unpack("CCx6Vv", offset: 6 + 14)
    assert_equal "<assembly/>", again.tree[24][1][1033]
    assert_equal [1, 2], again.tree[6].keys.sort # string bundles 0 and 1

    sections = out.unpack1("v", offset: 0x40 + 6)
    assert_equal 2, sections
    rva, size = out.unpack("VV", offset: 0x40 + 24 + 112 + 16)
    assert_equal 0x2000, rva
    assert_operator size, :>, 0
    assert_equal 0x3000, out.unpack1("V", offset: 0x40 + 24 + 56) # SizeOfImage grew
  end

  def test_rewriting_keeps_existing_resources
    first = Ocran::PeResources.new(minimal_pe).tap { |pe| pe.set_manifest("<a/>") }.to_bytes
    second = Ocran::PeResources.new(first)
    second.set_version_info("V2".b)
    again = Ocran::PeResources.new(second.to_bytes)
    assert_equal "<a/>", again.manifest
    assert_equal "V2", again.tree[16][1][1033]
    # The superseded section is renamed, not moved.
    names = (0...3).map { |i| second.to_bytes.byteslice(0x40 + 24 + 240 + i * 40, 8).delete("\0") }
    assert_equal [".text", ".rsrc_o", ".rsrc"], names
  end

  def test_named_resources_round_trip
    pe = Ocran::PeResources.new(minimal_pe)
    pe.tree["CUSTOM"] = { "MYDATA" => { 0 => "payload".b } }
    again = Ocran::PeResources.new(pe.to_bytes)
    assert_equal "payload", again.tree["CUSTOM"]["MYDATA"][0]
  end

  def test_rejects_what_is_not_an_icon
    assert_raises(RuntimeError) { Ocran::PeResources.new(minimal_pe).set_icon("PNG....") }
  end
end
