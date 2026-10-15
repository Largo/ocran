# Checks that Windows executables import only DLLs that ship with Windows:
# each one must be an API set (api-ms-win-*) or be in System32, and none may
# be a compiler runtime (the VC++ redistributable is installed on CI
# runners, so being in System32 does not prove that for vcruntime140.dll).
#
#   ruby -I lib runtime/smoke/check-pe-imports.rb EXE...
require "ocran/pe_imports"

system32 = File.join(ENV.fetch("SystemRoot", "C:/Windows"), "System32")
compiler_runtime = /\A(vcruntime|msvcp|concrt|ucrtbased|libgcc|libstdc\+\+|libwinpthread)/i
# A glob that matched nothing must not pass as "all checked".
abort "check-pe-imports.rb: no executables to check" if ARGV.empty?

failed = false
ARGV.each do |exe|
  dlls = Ocran::PEImports.dll_names(exe).uniq.sort_by(&:downcase)
  bad = dlls.select do |dll|
    dll.match?(compiler_runtime) || !(dll.downcase.start_with?("api-ms-win-") || File.exist?(File.join(system32, dll)))
  end
  puts "#{exe}: #{dlls.join(", ")}"
  next if bad.empty?

  warn "#{exe} imports DLLs that do not ship with Windows: #{bad.join(", ")}"
  failed = true
end
exit 1 if failed
