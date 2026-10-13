# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/ocran/pe_imports"

# Unit tests for Ocran::PEImports. The images are synthesized here, so the
# tests run on every host and no real DLL is needed.
class TestPEImports < Minitest::Test
  SECTION_RVA = 0x1000
  SECTION_RAW = 0x200
  IMPORTS_RVA = 0x1000
  DELAY_IMPORTS_RVA = 0x1100
  NAMES_RVA = 0x1180

  # A minimal PE image with one section that holds an import table naming
  # +imports+ and a delay-load import table naming +delay_imports+.
  def pe_image(imports, delay_imports, pe32plus: true)
    image = "\0".b * 0x400
    put = ->(offset, format, *values) { image[offset, [*values].pack(format).bytesize] = [*values].pack(format) }
    raw = ->(rva) { rva - SECTION_RVA + SECTION_RAW }

    put.(0, "a2", "MZ")
    put.(0x3c, "V", 0x40)
    put.(0x40, "a4", "PE\0\0")
    optional_header_size = pe32plus ? 240 : 224
    put.(0x44, "vv", 0x8664, 1)    # Machine, NumberOfSections
    put.(0x54, "v", optional_header_size)
    optional = 0x58
    put.(optional, "v", pe32plus ? 0x20b : 0x10b)
    directories = optional + (pe32plus ? 112 : 96)
    put.(directories - 4, "V", 16) # NumberOfRvaAndSizes
    put.(directories + 1 * 8, "VV", IMPORTS_RVA, 20 * (imports.size + 1))
    put.(directories + 13 * 8, "VV", DELAY_IMPORTS_RVA, 32 * (delay_imports.size + 1))
    section = optional + optional_header_size
    put.(section, "a8VVVV", ".idata", 0x200, SECTION_RVA, 0x200, SECTION_RAW)

    name_rva = NAMES_RVA
    name_rvas = (imports + delay_imports).map do |name|
      put.(raw.(name_rva), "Z*", name)
      name_rva.tap { name_rva += name.bytesize + 1 }
    end
    imports.each_index do |i|
      put.(raw.(IMPORTS_RVA) + i * 20 + 12, "V", name_rvas[i])
    end
    delay_imports.each_index do |i|
      put.(raw.(DELAY_IMPORTS_RVA) + i * 32, "VV", 1, name_rvas[imports.size + i])
    end
    image
  end

  def dll_names(image)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "image.dll")
      File.binwrite(path, image)
      Ocran::PEImports.dll_names(path)
    end
  end

  def test_imports_and_delay_load_imports_are_read
    image = pe_image(%w[gmp-10.dll VCRUNTIME140.dll], %w[delayed.dll])
    assert_equal %w[gmp-10.dll VCRUNTIME140.dll delayed.dll], dll_names(image)
  end

  def test_pe32_images_are_read
    image = pe_image(%w[KERNEL32.dll], [], pe32plus: false)
    assert_equal %w[KERNEL32.dll], dll_names(image)
  end

  def test_a_dll_imported_twice_is_reported_once
    image = pe_image(%w[libffi-8.dll], %w[LIBFFI-8.DLL])
    assert_equal %w[libffi-8.dll], dll_names(image)
  end

  def test_files_that_are_not_pe_images_have_no_imports
    assert_equal [], dll_names("#!/bin/sh\n")
    assert_equal [], dll_names("MZ")
    assert_equal [], dll_names(pe_image(%w[a.dll], [])[0, 0x150])
    assert_equal [], Ocran::PEImports.dll_names(File.join(Dir.tmpdir, "ocran-no-such-file.dll"))
  end
end
