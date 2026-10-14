# Native no-extraction runtime

A single Windows `.exe` that runs a Ruby application **without extracting
anything**: no temp directory, no DLLs written to disk. Built with
`ocran app.rb --native <runtime-dir>` (see the main README); this directory
holds how the runtime is built and how it works.

```
app.exe = ocran-runtime.exe  +  ZIP archive (the application)
```

* **`ocran-runtime.exe`** is a statically linked Ruby (x64, UCRT). Every
  extension and its C library is linked in: openssl, psych/libyaml, zlib,
  fiddle/libffi, bigdecimal, racc, win32ole. It imports nothing but Windows
  system DLLs (`kernel32`, `ws2_32`, `crypt32`, `ole32`, ... and the
  `api-ms-win-crt-*` UCRT, part of Windows 10+). No VC++ redistributable.
* **The archive** is a plain ZIP with offsets relative to the start of the
  file, so `unzip -l app.exe` or 7-Zip list exactly what will run.
* **Authenticode signing** works: the archive sits before the certificate
  table, so the signature covers the whole application.

## How it starts

1. `ocran_main.c` runs Ruby as
   `--disable=gems,rubyopt -e <stage0> -- <user args>`. User arguments can
   never be read as interpreter options, and `RUBYOPT` is ignored.
2. `stage0.rb` (compiled into the runtime) clears `$LOAD_PATH`, indexes the
   archive and evaluates `ocran/boot.rb` from it.
3. `boot.rb` (`lib/ocran/native/boot.rb`, packed by ocran) serves the archive as a read-only tree rooted
   at the exe's own path (`C:/apps/tool.exe/src/app.rb`), sets `$LOAD_PATH`
   from `ocran/config.rb`, and runs the main script.

A path below an existing *file* can never exist on disk, so an archive path
cannot be shadowed by a planted file. Whatever `boot.rb` does not intercept
fails with `ENOTDIR` instead of silently reading something else. It
intercepts `require`, `require_relative`, `load`, `Kernel#open`, and a
fixed list of read-only `File`/`IO`/`Dir` queries (see the header of
`boot.rb`), and then loads RubyGems, so gems activate as usual.

MRI patches (`patches/`, `mswin/patches/`), each a few lines:

* `ruby-require-dispatch.patch`: C-level `rb_require` dispatches through
  `Kernel#require`, as `autoload` already does, so C extensions and core
  (`String#unicode_normalize`, json, psych) see the archive too.
* `ruby-openssl-winstore.patch`: `OpenSSL::X509::Store#set_default_paths`
  also loads OpenSSL's Windows certificate store (`org.openssl.winstore://`,
  OpenSSL 3.2+), so certificates verify as they do for Windows itself,
  without a CA file. This is what openssl-win-root does by exporting the
  ROOT store to PEM files on disk; OpenSSL looks the certificates up in
  the store directly, in memory.
* `mswin/ruby-win32-static-crt.patch`: see below.

OpenSSL's compiled-in directories (configuration, certificates, engines)
are set to its Windows defaults under `C:\Program Files`, which only
administrators can write. Left at the build prefix they would resolve to
`C:\root\...` on the user's machine, a directory any user can create.

## Licenses

The runtime is statically linked; see [LICENSES.md](LICENSES.md). The
build collects the license texts of everything linked in into `LICENSES/`
of the runtime directory, and ocran packs them into every executable as
`ocran/licenses/`. GNU libiconv and FreeTDS (LGPL) are also built as DLLs,
which `ocran --native-dll iconv,sybdb` ships next to the executable
instead of linking them in.

## C extensions of the application's gems

A gem's C extension cannot be loaded from inside the executable, so it is
linked into it. The runtime directory carries an SDK (`sdk/`, written by
`make-sdk.rb` / `mswin/make-sdk.rb`): the runtime's link inputs and link
command (`link.args`), Ruby's headers, the target's `rbconfig.rb` (and for
MinGW Ruby's cross-build `<arch>-fake.rb`), the static C libraries, and the
gem extensions already linked in. At packaging time ocran builds each
missing extension from the gem's source with
`lib/ocran/native/build_static_ext.rb` (extconf.rb and make, as RubyGems
would, but to a static library) and links a runtime with it registered
(`Ocran::NativeSdk#link`). The runtime's own build uses the same code.
Tested: bcrypt (MinGW, packaged on Linux and on Windows with MSYS2 GCC 16
against an SDK built with Debian's GCC 14) and jaro_winkler (mswin).

## Building

```
native/build-runtime.sh [build-dir]        # Linux, gcc-mingw-w64-ucrt64
```

Sources are pinned with SHA-256 in `sources.lock`. `pkg-config` only sees
the cross-built dependencies. Timestamps and build paths are fixed for
reproducible output. Results in `<build-dir>/out`:

| | |
|---|---|
| `ocran-runtime.exe` | the runtime |
| `lib/ruby/` | standard library and bundled gems (packed from here) |
| `runtime.json` | version, architecture, load path, linked-in extensions, gems, SHA-256 of the exe (`write-runtime-info.rb`) |
| `sdk/` | for linking more C extensions in at packaging time (see below) |

`out/` minus `exts/` and `stage/` is the runtime directory to pass to
`ocran --native`.

The bundled gems' C extensions (fiddle, bigdecimal, racc, win32ole) are
built and linked in the same way as an application's (see below).

### mswin (MSVC Build Tools)

The same runtime can be built with Visual Studio Build Tools, on Windows:

```
native\mswin\build-ruby.cmd ROOT native\patches native\mswin\patches
ROOT\stage\bin\ruby.exe native\mswin\build-gemexts.rb ROOT
ROOT\stage\bin\ruby.exe native\mswin\make-sdk.rb ROOT\build ROOT\src ROOT\deps\installed\x64-windows-static ROOT\sdk ROOT\exts\*.line
ROOT\stage\bin\ruby.exe native\link-runtime.rb ROOT\sdk x64-mswin64_140 runtime.exe
native\mswin\make-runtime-dir.cmd ROOT runtime.exe RUNTIME_DIR
```

`ROOT\src` is a Ruby checkout, `ROOT\baseruby` an official mswin build of
the same revision (from ruby-lang.org/pub/ruby/binaries/mswin64, checked
against its `.sha256`), and `ROOT\deps` holds vcpkg's
`x64-windows-static` libffi, libyaml, openssl and zlib (`vcpkg.json` with a
pinned `builtin-baseline`). Gem extensions are built with
`mswin/build-gemexts.rb`, run by the freshly installed Ruby.

Everything is compiled with **`-MT` (static CRT)**: the runtime imports only
Windows system DLLs - not even `vcruntime140.dll` or the UCRT - and runs on
a machine without the VC++ redistributable. Ruby does not support `-MT` as
shipped: `win32.c` finds the CRT's file-descriptor table by disassembling
`_isatty` in `ucrtbase.dll`, which is a different CRT instance from the
static one, so every descriptor is invalid (`puts` fails with `EBADF`).
`mswin/patches/ruby-win32-static-crt.patch` uses the static library's own
`__pioinfo` symbol instead.

The official mswin zip itself cannot be used as the runtime: its extensions
are DLLs, its C libraries are separate DLLs, and it needs the VC++
redistributable.

## Using it

```
ocran app.rb --native RUNTIME_DIR
```

Packaging works on Windows (the normal case: dependency detection sees
Windows-only libraries) and on Linux/macOS for applications that do not
need them; the build host's Ruby must have the runtime's API version.

## Known gaps

* A gem whose C extension needs a C library the SDK does not have (it has
  zlib, OpenSSL, libyaml, libffi, libiconv, libxml2, libxslt, FreeTDS)
  needs that library added to the runtime build first.
* The mswin runtime's SDK does not have libiconv, libxml2, libxslt and
  FreeTDS yet (nokogiri and tiny_tds need the MinGW runtime for now).
* OpenSSL cannot read a CA file packed inside the executable
  (`SSL_CERT_FILE`); the Windows store makes one unnecessary, and a custom
  one can be shipped next to the executable.
* `--icon` and the version-resource options are not applied to the
  runtime yet.
* Writes to archive paths through `File.write` report `ENOENT`, not `EROFS`.
* boot.rb defines Kernel's loading methods in Kernel itself (as RubyGems
  does) rather than prepending a module: in Ruby 4.0.6, once a `super`
  call site in a prepended module had run, a later redefinition of the
  method in the module it was prepended to (RubyGems' require) was not
  seen by it. Fixed in Ruby 4.0.7; defining the methods in place also
  composes with later redefinitions (Zeitwerk) either way.
