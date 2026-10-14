# Smoke test for a gem with a C extension and C libraries of its own
# (see run.rb, OCRAN_SMOKE_GEMS=1): nokogiri, built from source against the
# runtime's SDK (libxml2, libxslt) and linked into the executable.
require "nokogiri"

doc = Nokogiri::XML("<a><b>1</b><b>2</b></a>")
puts "html=#{Nokogiri::HTML("<p class='x'>héllo</p>").at_css("p.x").text}"
puts "xpath=#{doc.xpath("//b").map(&:text).join(",")}"
xslt = Nokogiri::XSLT(<<~XSL)
  <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
    <xsl:output method="text"/>
    <xsl:template match="/">sum=<xsl:value-of select="sum(//b)"/></xsl:template>
  </xsl:stylesheet>
XSL
puts "xslt=#{xslt.apply_to(doc)}"
exe = ENV["OCRAN_EXECUTABLE"]
from_disk = exe ? $LOADED_FEATURES.select { File.absolute_path?(_1) && !_1.start_with?(exe.tr("\\", "/")) } : []
puts "from_disk=#{from_disk.size}"
