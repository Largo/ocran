# Native no-extraction runtime (prototype)

A single Windows `.exe` that runs a Ruby application **without extracting
anything**: no temp directory, no DLLs written to disk. Not yet wired into
the `ocran` CLI.

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
3. `boot.rb` (in the archive) serves the archive as a read-only tree rooted
   at the exe's own path (`C:/apps/tool.exe/src/app.rb`), sets `$LOAD_PATH`
   from `ocran/config.rb`, and runs the main script.

A path below an existing *file* can never exist on disk, so an archive path
cannot be shadowed by a planted file. Whatever `boot.rb` does not intercept
fails with `ENOTDIR` instead of silently reading something else. It
intercepts `require`, `require_relative`, `load`, `Kernel#open`, and a
fixed list of read-only `File`/`IO`/`Dir` queries (see the header of
`boot.rb`).

One MRI patch (`patches/ruby-require-dispatch.patch`): C-level `rb_require`
dispatches through `Kernel#require`, as `autoload` already does, so C
extensions and core (`String#unicode_normalize`, json, psych) see the
archive too.

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
| `lib/ruby/` | standard library and bundled gems (packed into the archive) |
| `kit/` | the runtime's link inputs, for re-linking with an application's gem C extensions (`link-runtime.rb`) |

Gem C extensions are compiled to static archives by `build-static-ext.rb`
(extconf.rb + make against the cross build, as RubyGems would) and linked
in with `link-runtime.rb`.

### mswin (MSVC Build Tools)

The same runtime can be built with Visual Studio Build Tools, on Windows:

```
native\mswin\build-ruby.cmd ROOT native\patches native\mswin\patches
ROOT\stage\bin\ruby.exe native\mswin\build-gemexts.rb ROOT
ruby native\mswin\link-runtime.rb ROOT\build ROOT\src out.exe ROOT\exts\*.line
```

`ROOT\src` is a Ruby checkout, `ROOT\baseruby` an official mswin build of
the same revision (from ruby-lang.org/pub/ruby/binaries/mswin64, checked
against its `.sha256`), and `ROOT\deps` holds vcpkg's
`x64-windows-static` libffi, libyaml, openssl and zlib (`vcpkg.json` with a
pinned `builtin-baseline`). Gem extensions are built with
`build-static-ext.rb`, run by the freshly installed Ruby.

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

## Trying it

```
ruby native/pack-prototype.rb out/ocran-runtime.exe out/lib/ruby/4.0.0 app.exe app.rb [files...]
```

## Known gaps

* Not integrated into `ocran` yet: the prototype packs the whole stdlib
  rather than the detected dependencies, and does not activate RubyGems.
* Third-party gems with C extensions need re-linking the runtime at
  packaging time (needs the mingw-w64 UCRT toolchain).
* No windowed (`rubyw`) variant yet.
* Writes to archive paths through `File.write` report `ENOENT`, not `EROFS`.
