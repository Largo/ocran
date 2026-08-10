# Loads a DLL the way fat binary gems with bundled libraries do (e.g.
# tiny_tds loading FreeTDS from its ports/ directory): by absolute path
# from a directory the Windows loader does not search when it resolves
# the imports of a native extension at runtime. The test copies a real
# DLL to ports/bin/fakeports.dll before building.
if ENV["OCRAN_EXECUTABLE"]
  # Runtime: the DLL must have been bundled next to ruby.exe (bin), the
  # only location that resolves in every DLL search mode.
  require "rbconfig"
  bundled = File.join(RbConfig::CONFIG["bindir"], "fakeports.dll")
  exit(File.exist?(bundled) ? 104 : 1)
else
  # Dependency run: load the DLL so it shows up as a detected DLL.
  require "fiddle"
  Fiddle.dlopen(File.expand_path("ports/bin/fakeports.dll", __dir__))
end
