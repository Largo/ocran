# Static runtime (no extraction)

A single executable, for Windows, Linux or macOS, that runs a Ruby application
**without extracting anything**: no temp directory, no DLLs or shared
libraries written to disk. Built with
`ocran app.rb --static-runtime <runtime-dir>` (see the main README); this
directory holds how the runtime is built and how it works.

```
app.exe = ocran-runtime.exe  +  ZIP archive (the application)    Windows
app     = ocran-runtime      +  ZIP archive (the application)    Linux
app     = ocran-runtime objects, linked with the ZIP archive
          as section __OCRAN,__zip                                macOS
```

The system the executable runs on is the runtime's, whatever the build
host is.

* **`ocran-runtime.exe`** is a statically linked Ruby (x64, UCRT). Every
  extension and its C library is linked in: openssl, psych/libyaml, zlib,
  fiddle/libffi, bigdecimal, racc, win32ole. It imports nothing but Windows
  system DLLs (`kernel32`, `ws2_32`, `crypt32`, `ole32`, ... and the
  `api-ms-win-crt-*` UCRT, part of Windows 10+). No VC++ redistributable.
* **The archive** is a plain ZIP with offsets relative to the start of the
  file, so `unzip -l app.exe` or 7-Zip list exactly what will run.
* **Authenticode signing** works: the archive sits before the certificate
  table, so the signature covers the whole application.
* **`ocran-runtime`** (Linux, `linux/build-runtime.sh`) is the same Ruby
  linked against musl into a fully static ELF executable: no dynamic
  loader, no libc dependency. One binary runs on any x86_64 distribution -
  tested on Debian, Fedora, Alpine and BusyBox. OpenSSL finds the system's
  CA bundle wherever the distribution keeps it.
* **macOS** (`macos/build-runtime.sh`): the same Ruby, linked statically
  except for libraries of macOS itself (libSystem, libiconv,
  CoreFoundation; `otool -L` lists them). A Mach-O executable must stay
  validly signed - arm64 runs nothing unsigned - and data appended after
  the signature breaks it, so the archive cannot simply be appended.
  Instead ocran links every executable at packaging time from the
  runtime's SDK, with the archive as a section of its own (`-sectcreate
  __OCRAN __zip`); the linker lays it out and signs the whole ad hoc, and
  `codesign` can sign it again with a real identity. The archive's offsets
  count from the start of the section:
  `segedit app -extract __OCRAN __zip app.zip` gives a plain ZIP.

## How it starts

1. `ocran_main.c` runs Ruby as
   `--disable=gems,rubyopt -e <stage0> -- <user args>`. User arguments can
   never be read as interpreter options, and `RUBYOPT` is ignored.
2. `stage0.rb` (compiled into the runtime) clears `$LOAD_PATH`, indexes the
   archive (at the end of the file, before an Authenticode certificate
   table, or in the Mach-O section) and evaluates `ocran/boot.rb` from it.
3. `boot.rb` (`lib/ocran/static_runtime/boot.rb`, packed by ocran) serves the archive as a read-only tree rooted
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
* `ruby-openssl-system-store.patch`: `OpenSSL::X509::Store#set_default_paths`
  also trusts what the operating system trusts. On Windows it loads
  OpenSSL's Windows certificate store (`org.openssl.winstore://`, OpenSSL
  3.2+), which looks certificates up in the ROOT store as needed, in memory
  - what openssl-win-root does by exporting the store to PEM files on disk.
  Elsewhere it loads the system's CA bundle from where distributions (and
  macOS) keep it, since a static OpenSSL only knows its compiled-in paths.
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
which `ocran --runtime-dll iconv,sybdb` ships next to the executable
instead of linking them in.

## C extensions of the application's gems

A gem's C extension cannot be loaded from inside the executable, so it is
linked into it. The runtime directory carries an SDK (`sdk/`, written by
`make-sdk.rb` / `mswin/make-sdk.rb`): the runtime's link inputs and link
command (`link.args`), Ruby's headers, the target's `rbconfig.rb` (and for
MinGW Ruby's cross-build `<arch>-fake.rb`), the static C libraries, and the
gem extensions already linked in. At packaging time ocran builds each
missing extension from the gem's source with
`lib/ocran/static_runtime/build_static_ext.rb` (extconf.rb and make, as RubyGems
would, but to a static library) and links a runtime with it registered
(`Ocran::RuntimeSdk#link`). The runtime's own build uses the same code.
Tested: bcrypt (MinGW, packaged on Linux and on Windows with MSYS2 GCC 16
against an SDK built with Debian's GCC 14) and jaro_winkler (mswin).

## Prebuilt runtimes and attestations

CI builds every runtime from the pinned sources and tests it before
publishing it, as a workflow artifact and, for a release, as an asset of
the GitHub release (from 1.5.1 on; the release workflow calls the three
runtime workflows and attaches what they built):
`static-runtime-windows.yml` (cross-built on Linux, tested on Windows with
executables packaged on Linux and on Windows), `static-runtime-linux.yml`
(tested on Ubuntu and in Alpine, BusyBox, Fedora and Debian containers) and
`static-runtime-macos.yml` (arm64). Each artifact is one reproducible
archive (`pack-runtime.rb`: sorted entries, fixed times, no owners):
`ocran-runtime-<ruby version>-<arch>.zip` for Windows, which Explorer and
`Expand-Archive` unpack, `.tar.gz` for Linux and macOS.

Only a runtime that passed its tests gets a signed
[build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations)
(SLSA provenance, signed through Sigstore with the workflow's identity) for
the archive and for the runtime executable in it. It records which
workflow, at which commit of this repository, built that exact file:

```
gh attestation verify ocran-runtime-4.0.7-x64-mingw-ucrt.zip -R Largo/ocran
Expand-Archive ocran-runtime-4.0.7-x64-mingw-ucrt.zip .
gh attestation verify ocran-runtime-4.0.7-x64-mingw-ucrt/ocran-runtime.exe -R Largo/ocran
```

An attestation says where a runtime was built, not that its sources are
sound: those are pinned by SHA-256 in `sources.lock`, and the build
scripts and patches are in this directory. `runtime.json` records the
executable's SHA-256, which ocran checks before every packaging run.

## Building

```
runtime/build-runtime.sh [build-dir]        # Linux, gcc-mingw-w64-ucrt64
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
`ocran --static-runtime`.

The bundled gems' C extensions (fiddle, bigdecimal, racc, win32ole) are
built and linked in the same way as an application's (see below).

### Linux (musl)

```
runtime/linux/build-runtime.sh [build-dir]    # Debian/Ubuntu: musl-tools, linux-libc-dev
```

Same sources (`sources.lock`, minus GNU libiconv: musl has its own
iconv) and the same steps as the MinGW build, cross-compiled for
`x86_64-linux-musl` with `musl-gcc` and Ruby's `<arch>-fake.rb`. The SDK
works the same; ocran builds gem extensions with `musl-gcc`
(`OCRAN_RUNTIME_CC` to use another musl compiler). A fully static
executable cannot load shared libraries, so `--runtime-dll` does not exist
for it.

### macOS

```
runtime/macos/build-runtime.sh [build-dir]    # on a Mac: clang, make, a Ruby 4.0
```

A native build with clang, the same sources and steps; the host Ruby poses
as the runtime through Ruby's `<arch>-fake.rb` for building the gem
extensions, as in the cross builds. It targets the Mac it runs on
(`uname -m`) and macOS 12 and later (`MACOSX_DEPLOYMENT_TARGET`). The
runtime directory always needs `sdk/`, since every executable is linked
from it. CI (`.github/workflows/static-runtime-macos.yml`) builds the arm64
runtime on `macos-15` and runs `smoke/` with it;
`static-runtime-linux.yml` does the same for the Linux runtime on Ubuntu
and runs the executables in Alpine, BusyBox, Fedora and Debian containers.

### Smoke tests

```
ruby runtime/smoke/run.rb RUNTIME_DIR [OUT_DIR]   # OCRAN_SMOKE_NETWORK=1 adds HTTPS
```

packages the applications in `smoke/` with a runtime and runs them:
reading files, `require_relative`, autoload, `DATA`, json, psych, zlib,
digest, arguments, the exit status, and that every loaded file comes from
inside the executable; HTTPS with the system's trust store, and that an
untrusted certificate is refused. Executables for another system are only
built. `OCRAN_SMOKE_GEMS=1` adds nokogiri (installed for the build host's
Ruby), built from source against the runtime's SDK at packaging time.

### mswin (MSVC Build Tools)

The same runtime can be built with Visual Studio Build Tools, on Windows:

```
runtime\mswin\build-ruby.cmd ROOT runtime\patches runtime\mswin\patches
ROOT\stage\bin\ruby.exe runtime\mswin\build-gemexts.rb ROOT
ROOT\stage\bin\ruby.exe runtime\mswin\make-sdk.rb ROOT\build ROOT\src ROOT\deps\installed\x64-windows-static ROOT\sdk ROOT\exts\*.line
ROOT\stage\bin\ruby.exe runtime\link-runtime.rb ROOT\sdk x64-mswin64_140 runtime.exe
runtime\mswin\make-runtime-dir.cmd ROOT runtime.exe RUNTIME_DIR
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
ocran app.rb --static-runtime RUNTIME_DIR
```

The runtime decides what the executable is for. Packaging works from any
build host whose Ruby has the runtime's API version; dependency detection
runs on the build host, so platform-specific libraries are only seen when
packaging on the target system (for Windows, the runtime's `win32/` files
are always packed). Building gem C extensions needs the runtime's
compiler on the build host (see the main README).

## Known gaps

* A gem whose C extension needs a C library the SDK does not have (it has
  zlib, OpenSSL, libyaml, libffi, libiconv, libxml2, libxslt, FreeTDS)
  needs that library added to the runtime build first.
* The mswin runtime's SDK does not have libiconv, libxml2, libxslt and
  FreeTDS yet (nokogiri and tiny_tds need the MinGW runtime for now).
* Linux: x86_64 only so far (aarch64 needs a musl cross compiler).
* macOS: tested on arm64 only (an x86_64 build should work the same way
  on an Intel Mac); packaging needs a Mac, since every executable is
  linked; `--runtime-dll` does not exist yet. Signing with a Developer ID
  and notarization are untested.
* OpenSSL cannot read a CA file packed inside the executable
  (`SSL_CERT_FILE`); the Windows store makes one unnecessary, and a custom
  one can be shipped next to the executable.
* Writes to archive paths through `File.write` report `ENOENT` (Windows) or
  `ENOTDIR` (Linux), not `EROFS`.
* boot.rb defines Kernel's loading methods in Kernel itself (as RubyGems
  does) rather than prepending a module: in Ruby 4.0.6, once a `super`
  call site in a prepended module had run, a later redefinition of the
  method in the module it was prepended to (RubyGems' require) was not
  seen by it. Fixed in Ruby 4.0.7; defining the methods in place also
  composes with later redefinitions (Zeitwerk) either way.
