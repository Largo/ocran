# Links an ocran runtime executable from an SDK directory (see make-sdk.rb)
# with the given gem extensions registered in addition to the SDK's own:
#
#   ruby native/link-runtime.rb SDK_DIR ARCH OUT.exe [EXT_LINE_FILE...]
#
# The same code (Ocran::NativeSdk#link) links a runtime with an
# application's gem extensions at packaging time.
require_relative "../lib/ocran/native_sdk"

sdk, arch, out, *ext_files = ARGV
abort "usage: link-runtime.rb SDK_DIR ARCH OUT.exe [EXT_LINE_FILE...]" unless out
sdk = Ocran::NativeSdk.new(sdk, arch: arch)
extra = ext_files.map { |f| Ocran::NativeSdk::Extension.parse(File.read(f), sdk.dir) }
puts sdk.link(extra, out)
