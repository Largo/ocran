# Compiling the OCRAN stub with cosmocc (Cosmopolitan Libc)

Status: **experimental — the POSIX stub compiles and passes an
end-to-end smoke test with cosmocc, and a cosmopolitan-built Ruby can
now be packaged as the interpreter payload (`--cosmo-ruby`), verified
end-to-end on Linux**. Tracking issue:
[#26](https://github.com/largo/ocran/issues/26).

## Goal

Long-term, make the launcher stub buildable against
[Cosmopolitan Libc](https://github.com/jart/cosmopolitan) (`cosmocc`), so
it can be maintained against a POSIX-style API surface instead of raw
Win32, and so a single Actually Portable Executable (APE) stub could in
principle run on Windows, Linux and macOS.

## Where we already are

The stub was modularized some time ago and the Win32 surface is already
isolated behind one backend file:

| File | Role |
|------|------|
| `src/stub.c` | `main()` — platform-neutral, calls only the `system_utils.h` API |
| `src/system_utils.h` | Platform abstraction API (paths, mmap, process, env, signals) |
| `src/system_utils.c` | **Windows backend** (mingw build) |
| `src/system_utils_posix.c` | **POSIX backend** (Linux/macOS build; also the cosmocc target) |
| `src/unpack.c` | Opcode parsing; small `#ifdef _WIN32` islands (Authenticode/PE handling) |
| `src/inst_dir.c` | Extraction dir; symlink support guarded `#ifndef _WIN32` |
| `src/error.c` / `error.h` | Logging; `MessageBox` only in the `_WIN32` GUI (`stubw`) build |
| `src/Makefile` | Selects backend by `uname`; POSIX hosts build a native `stub` |

So "port stub.c to POSIX" is essentially done; the cosmocc question
reduces to "does the POSIX backend compile and run under Cosmopolitan?"

## Win32 API inventory (the mingw backend, `system_utils.c`)

For reference, the Windows-only API surface that the POSIX backend
replaces:

| Win32 API | Purpose | POSIX / Cosmopolitan equivalent |
|-----------|---------|--------------------------------|
| `CreateFileW` / `CreateFileMappingW` / `MapViewOfFile` | map own exe | `open` + `mmap` (works under cosmo) |
| `GetModuleFileNameW` | own exe path | `/proc/self/exe` (Linux), `_NSGetExecutablePath` (macOS), **`GetProgramExecutableName()` (cosmo)** |
| `GetTempPathW` | temp dir | `$TMPDIR` else `/tmp` (cosmo maps `/tmp` to the host temp dir on Windows) |
| `CreateDirectoryW` / `DeleteFileW` / `RemoveDirectoryW` / `FindFirstFileW`… | dir tree create/delete | `mkdir` / `unlink` / `rmdir` / `opendir`+`readdir` |
| `BCryptGenRandom` | unique temp dir name | `mkdtemp` |
| `CreateProcessW` + `WaitForSingleObject` + `GetExitCodeProcess` | launch ruby | `fork` + `execv` + `waitpid` (cosmo emulates via `CreateProcess` on Windows) |
| `SetEnvironmentVariableW` | env vars | `setenv` / `unsetenv` |
| `SetConsoleCtrlHandler` | ignore Ctrl-C during cleanup | `sigaction(SIGINT/SIGTERM, SIG_IGN)` |
| `GetLongPathNameW` | 8.3-name normalization | not needed on POSIX (`ToLongPath` = `strdup`) |
| `WideCharToMultiByte` / `MultiByteToWideChar` | UTF-8 ↔ UTF-16 | not needed (cosmo is UTF-8 throughout, converts internally on Windows) |
| `MessageBox` (error.c, `stubw` only) | GUI fatal errors | stderr only (no GUI stub under cosmo) |
| `IMAGE_NT_HEADERS` walk (unpack.c) | find OCRAN signature in Authenticode-signed exes | not compiled; POSIX branch scans signature at EOF |

## Cosmocc findings (cosmocc 14.1.0 / GCC 14.1.0, 2025-01-05 toolchain)

Baseline attempt: `make -C src CC=cosmocc` (GNU make command-line
variables already override the Makefile's `CC := gcc`, so no Makefile
change was needed for this).

**Exactly one compile error** in the whole tree:

```
system_utils_posix.c:380:2: error: #error "GetImagePath not implemented for this platform"
```

Cause: cosmocc defines `__COSMOPOLITAN__`/`__COSMOCC__` but deliberately
*neither* `__linux__` nor `__APPLE__` (an APE binary decides its host OS
at run time, not compile time), so `GetImagePath()` fell through to the
`#error` branch. Everything else — `mmap`, `mkdtemp`, `sigaction`,
`fork`/`execv`/`waitpid`, `dirent`, LZMA — compiled warning-free.

Fix (in this branch): `GetImagePath()` gained a `__COSMOPOLITAN__`
branch that uses `GetProgramExecutableName()` from `<cosmo.h>`, which
resolves the executable path on every OS the APE runs on.

### Verification performed

* `make -C src` (native gcc, Linux): builds `stub` (ELF), unchanged
  behavior.
* `make -C src CC=cosmocc`: builds `stub` as an APE (~700 KB), zero
  warnings.
* End-to-end smoke test on Linux for **both** binaries: appended a
  hand-packed payload (modes byte `DEBUG|AUTO_CLEAN_INST_DIR`,
  `OP_CREATE_FILE` of a shell script, `OP_SETENV`, `OP_SET_SCRIPT`,
  offset + OCRAN signature). Both stubs extracted to a fresh
  `$TMPDIR/ocranXXXXXX` dir, launched the app, propagated its exit code
  (42), and auto-cleaned the extraction dir.

## Build integration

* **Build-at-packaging-time (implemented):** the stub sources are
  compiled with cosmocc during the packaging run and the app is packaged
  with the fresh APE stub (default output extension `.com`).
  Implementation: `lib/ocran/cosmo_toolchain.rb` (path resolution,
  compile via `make -C src stub CC=cosmocc` in a temp copy of `src/`,
  compiler output surfaced on failure, results cached in `~/.cache/ocran`
  keyed on toolchain + source hash). The binary platform gems now ship
  `src/` so this works from an installed gem, not just a checkout.
* **Toolchain discovery (implemented):** the toolchain does not have to
  be named on the command line. `CosmoToolchain.find_cc` looks at the
  `COSMOCC` environment variable (authoritative — a broken value is an
  error, not a silent fallback), then `cosmocc` in `PATH`, then the
  conventional install locations in `CONVENTIONAL_CC_PATHS`
  (`~/.cosmocc/*/bin/cosmocc`, `~/cosmocc/*/bin/cosmocc`,
  `/opt/cosmocc/*/bin/cosmocc`, `/opt/cosmo/bin/cosmocc`,
  `/usr/local/cosmocc/bin/cosmocc`; versioned directories sort newest
  first). `--cosmo <path>` remains an explicit override that always wins,
  and is what a stub developer, CI job or newer-toolchain user reaches
  for. The lookup runs during option parsing
  (`Option#parse`, `CosmoToolchain.require_cc`), so a missing toolchain
  fails before the dependency run, with a message naming the environment
  variable, `PATH`, the conventional locations and the download URL.
  Consequence: **`ocran app.rb --cosmo-ruby ruby.com` is a complete
  command line** — one option, everything else inferred.
* Shipping a *prebuilt* APE stub inside the gem was considered as an
  alternative (one APE stub is valid for every target OS, so it would
  remove the toolchain requirement entirely) and rejected: it adds
  ~700 KB to every gem for a feature most users never touch.
* Manual: `make -C src CC=cosmocc` with `cosmocc` on `PATH`
  (single ~440 MB zip from <https://cosmo.zip/pub/cosmocc/cosmocc.zip>).
* CI sketch (phase 1): a Linux job that caches the pinned cosmocc zip,
  builds `src` with `CC=cosmocc`, and runs the existing POSIX test path
  against the APE stub. The mingw/RubyInstaller jobs stay untouched —
  cosmocc is an *additional* backend, not a replacement.

## Cosmopolitan Ruby as the payload (`--cosmo-ruby`)

Phase 2 of the effort: `ocran app.rb --cosmo-ruby <ruby.com>` packages a
cosmopolitan-built Ruby APE as the bundled interpreter, so the produced
`.com` contains **both** an APE stub and an APE Ruby — no host-native
code at all. The cosmocc toolchain for the stub is discovered on the
build host (see "Build integration" above); `--cosmo <toolchain>` may be
added to pin a specific one. Verified end-to-end on Linux
against a cosmopolitan Ruby 4.0.0 build (`+PRISM +MIMALLOC`,
`x86_64-cosmo`, statically linked extensions).

### Findings the design rests on

* **The payload is fully self-contained.** An APE is also a ZIP archive;
  cosmopolitan Ruby embeds its complete standard library, native
  extensions (statically linked) and default/bundled gems in that store.
  Copied alone to an empty directory and run with `env -i`, its
  `$LOAD_PATH` is entirely `/zip/lib/ruby/...` and `require "json"` /
  `require "yaml"` work. Nothing of the Ruby installation needs to be
  packed besides the single APE file (packed as `bin/ruby.com`).
* **The APE stub can `execv` an APE directly.** Cosmopolitan Libc's own
  `execve` recognizes APE binaries and bootstraps them itself, so the
  stub's existing `fork`+`execv` launch path (`system_utils_posix.c`)
  launches `ruby.com` without changes — even on kernels with no APE
  binfmt registration and no `ape` loader installed (verified on such a
  host). Only *outside* processes (shells, `env`) need the ENOEXEC
  shell-script fallback; that is how the outer `.com` itself starts.
* **Build-time query.** The payload is executed once at packaging time
  (via `/bin/sh ruby.com -e ...`, the portable invocation) to validate
  it runs on the build host and to read `RUBY_VERSION`,
  `Gem.default_dir` and its provided gem names.
* **`GEM_PATH` must include the `/zip` gem dir.** Setting `GEM_PATH`
  stops RubyGems from scanning its compiled-in default directory —
  which for the payload is `/zip/lib/ruby/gems/<version>` inside the
  binary. OCRAN appends the queried directory to the packed `GEM_PATH`
  so the payload's bundled gems stay reachable.

### Packaging semantics

* Dependency detection still runs under the **host** Ruby; a warning is
  printed when host and payload versions differ (e.g. 3.3 vs 4.0),
  since stdlib/gem layout may have drifted between them.
* Host stdlib files, `libruby`, detected shared libraries, encoding
  `.so` files and `--add-all-core` trees are **not** packed; `RUBYLIB`
  only carries the app's own load paths. Stdlib requires resolve from
  `/zip` at runtime.
* Pure-Ruby gems are packed exactly as before (mirrored under the gem
  home / prefix layout, activated via `GEM_PATH`); verified with a
  host-installed pure gem despite the 3.3→4.0 skew.
* Host default gems are never packed (the payload ships its own).
  Native gems: if the payload provides the same gem (`json`, `psych`,
  `sqlite3`, ...), the host copy is skipped in its favor; otherwise the
  build **fails** with a clear message rather than producing a broken
  binary. Stray `.so`/`.bundle`/`.dll` files in gem file lists or
  features are excluded with a warning.
* "Native" is decided by `Direction.cosmo_gem_disposition`, which looks
  at `spec.extensions` **and** at the binaries the gem actually ships.
  A *precompiled platform gem* (e.g. `sqlite3-2.9.5-x86_64-linux-gnu`)
  has an **empty** `extensions` array — nothing is compiled at install
  time — yet carries `lib/sqlite3/<abi>/sqlite3_native.so`. Judging by
  `spec.extensions` alone let such a gem take the ordinary packing
  path: its `.so` files were dropped by the "contains native binaries"
  filter while its `.rb` files were packed into the app's gem home,
  where they shadow the payload's own copy of the gem and can mismatch
  the statically linked C extension the payload pre-registers (it only
  ran because host and payload happened to ship the same gem version).
  Both the gem directory and the extension directory are scanned for
  `.so`/`.bundle`/`.dll`.

### Limitations (v1)

* Console-only, POSIX build hosts only, and a cosmocc toolchain must be
  installed on the build host (it compiles the APE launcher stub);
  no toolchain is needed on the machines that *run* the result.
* Native-extension gems cannot be used at all unless the payload
  provides them.
* Host-vs-payload version skew is only warned about, not resolved; a
  gem packed for the host Ruby may still misbehave under a much newer
  payload Ruby.
* Only the single-file executable output is exercised; `--output-dir`,
  `--output-zip` and the macOS bundle share the same packaging code but
  their launch scripts have not been tested with an APE interpreter.
* The outer `.com` (APE stub + appended OCRAN payload) has been
  verified on Linux only; Windows/macOS behavior of the appended
  payload is still the pre-existing open risk 1 below.

### Field test: a real multi-gem CLI (2026-08-08)

Beyond the fixtures, a small but realistic application (`logstat`, an
access-log analyzer: 8 source files, `thor` + `terminal-table` +
`unicode-display_width` + `unicode-emoji` + `rainbow`, and `csv`,
`json`, `yaml`, `zlib`, `digest`, `stringio` from the stdlib) was packed
with `--cosmo-ruby` and the **same 10.9 MB `.com`** run on Linux
and on a Windows 11 x64 VM. Both produced byte-identical reports and the
same exit codes (0/1/2/3), including gzip-compressed input, a
`Marshal`+`Zlib` data file inside a gem (`display_width.marshal.gz`),
and UTF-8 table layout.

Path behavior of the packed app, same binary, per OS:

| Expression | Linux | Windows (cwd `C:\logstat`) |
|---|---|---|
| `ENV["OCRAN_EXECUTABLE"]` | `/tmp/run/logstat.com` | `/C/logstat/logstat.com` |
| `$0` / `__dir__` | `/tmp/ocranXXXXXX/src/...` | `/C/Users/…/AppData/Local/Temp/ocranXXXXXX/src/...` |
| `Dir.pwd` | `/tmp/run` | **`/logstat`** — no drive letter |
| `File::ALT_SEPARATOR` | `nil` | `nil` |

Takeaways for application authors and for the OCRAN docs:

* `OCRAN_EXECUTABLE` is the only reliable anchor for files that ship
  *next to* the executable; it is absolute and drive-qualified on both
  OSes. `__dir__`/`$0` point into the extraction directory, as on the
  native stub.
* `Dir.pwd` under the cosmopolitan Ruby on Windows returns a
  **drive-letter-less** path (`/logstat` for `C:\logstat`). Relative
  paths still resolve (cosmo interprets them against the current drive),
  but such a string is wrong as soon as it is stored, logged or passed
  to another process. Expand user-supplied paths against
  `OCRAN_EXECUTABLE`'s directory where "next to the exe" is meant, and
  do not assume `Dir.pwd` round-trips.
* Native Windows arguments (`C:\logstat\access.csv`) reach the app
  verbatim; an app that wants to accept them needs to map `X:\...` to
  `/X/...` itself. Cosmo does not do it for `File.open` in every path.
* Startup is dominated by extraction of the ~21 MB payload on every run:
  ~0.80 s on Linux, ~1.7 s on Windows (of which ~0.78 s / ~1.45 s is
  pure startup — the analysis itself is ~25 ms). An installed layout
  (`--output-dir`/`--output-zip` or the Inno Setup installer, which run
  in place and skip extraction entirely) is the obvious mitigation for
  latency-sensitive uses; `--chdir-first` is not one, it still extracts
  to a temporary directory and only chdirs into it.

Three rough edges found while doing this:

* **Precompiled platform gems were not recognized as native.** *(fixed)*
  A `sqlite3` app packed against a payload that has `sqlite3` linked in
  still got the *host* gem's `.rb` files packed (`.so` dropped by the
  file filter), because the payload-provides short-circuit was gated on
  `spec.extensions.any?` — false for `sqlite3-2.9.5-x86_64-linux-gnu`.
  It ran only because the packed `lib/sqlite3.rb` requires
  `sqlite3/sqlite3_native`, which the payload pre-registers, and both
  sides happened to be version 2.9.5. Detection now also looks at the
  binaries a gem ships; see "Packaging semantics" above.
* **Extraction directories leak when the process is killed.** On
  Windows, `app.com … | Select-Object -First 2` makes PowerShell
  terminate the native process when it closes the pipe; the stub never
  reaches its cleanup and leaves a full ~21 MB `%TEMP%\ocranXXXXXX`
  tree behind (reproducible 1:1). Normal exits, non-zero exits and
  `> $null` all clean up correctly, and Linux does not leak on the
  equivalent `| head -2`. See "Known limitation" below.
* **Dangling gemspecs with `--cosmo-ruby`.** A host gem whose spec lives
  in the RubyGems tree but whose code ships in the host stdlib (Debian's
  `/usr/share/rubygems-integration/all/specifications/csv-3.3.4.gemspec`
  with the implementation in `/usr/lib/ruby/vendor_ruby`) is packed as
  "0 files, 0 bytes": the spec is copied but every file it would
  contribute is skipped as part of the host Ruby installation. The
  packed spec then advertises a `full_gem_path` that does not exist.
  RubyGems tolerates this — `require "csv"` still resolves to the
  payload's own copy even when the phantom spec has the higher version
  (verified) — but the spec is dead weight and makes
  `Gem::Specification.find_all_by_name` report a gem that cannot be
  activated. Skipping the spec when the gem contributes no files under
  `--cosmo-ruby` would be the clean fix.

### Known limitation: leaked extraction dirs on abnormal termination

Investigated 2026-08-08 on a Windows 11 VM (PowerShell 5.1) with a
packed `.com` (APE stub + cosmopolitan Ruby 4.0.0 payload, ~21 MB).
**Not fixable inside the stub; documented instead of papered over.**

Repro (each run leaks exactly one directory; `before=0`):

```powershell
PS> .\lines.com | Select-Object -First 2     # app prints 10 lines
line0
line1
PS> $LASTEXITCODE
-1
PS> (Get-ChildItem $env:TEMP -Filter ocran* -Directory).Count
1                                            # ~20 MB, never reclaimed
PS> .\lines.com > $null; $LASTEXITCODE       # 0, cleans up
PS> .\lines.com                              # normal run, cleans up
```

Three consecutive piped runs left three directories (1 → 3); redirects
and normal/non-zero exits left none. On Linux the same binary with
`| head -2` leaks nothing: the stub's child dies of `EPIPE`/`SIGPIPE`,
`waitpid` returns and the normal cleanup path in `main()` runs.

Why no handler can fix it: PowerShell does not close the pipe and let
the writer notice — it **hard-kills** the upstream native process. The
control experiment uses no OCRAN code at all:

```powershell
PS> ruby atexit.rb | Select-Object -First 2   # native x64-mingw-ucrt ruby
line0
line1
PS> $LASTEXITCODE        # -1
PS> Test-Path atexit.log # False  -> at_exit never ran
PS> Test-Path sig.log    # False  -> no SIGINT/SIGTERM trap fired
```

Exit code `-1` is `Process.Kill()` → `TerminateProcess(handle, -1)`
(a console `CTRL_C_EVENT` would give `0xC000013A`). `TerminateProcess`
runs no console control handler, no signal handler, no `atexit`, and no
`DLL_PROCESS_DETACH` — so the `SIGPIPE`/`SIGTERM`/console-close handler
one would reach for cannot exist, in the cosmo build (POSIX backend) or
in the mingw build (`SetConsoleCtrlHandler` in `system_utils.c`) alike.
This is PowerShell behavior for *any* native command, not something the
cosmo port introduced. `FILE_FLAG_DELETE_ON_CLOSE` is no help either: it
applies to files, and Windows will not delete a directory that still has
open handles or children.

Options if this ever needs fixing (all outside the stub's exit path):

1. **Stale-directory sweep at startup.** Hold an open lock handle on a
   marker file inside the extraction directory for the lifetime of the
   process (Windows releases handles even on `TerminateProcess`; POSIX
   `flock` is released on death). A starting stub scans `%TEMP%` for
   `ocran*` dirs, tries to take the marker lock, and deletes only the
   ones whose owner is provably gone. Bounded, race-free, but new
   cross-platform code in `inst_dir.c` and needs its own test matrix.
2. **Deterministic extraction dir** keyed on a hash of the executable,
   reused across runs, so at most one stale tree exists per app (also
   removes the repeated ~1 s extraction cost). Changes concurrency and
   permission semantics.
3. **Ship an installed layout instead of a self-extracting binary**:
   `--output-dir`/`--output-zip` and the Inno Setup installer run the
   app in place from its own directory (`RUN_IN_EXE_DIR`) and never
   create a temporary extraction dir. Today's practical answer for apps
   that will be piped into `Select-Object`/`Select-String`. Note that
   `--chdir-first` is *not* a workaround: it only chdirs into the
   temporary extraction directory, which is still created.

The cosmopolitan Ruby payload itself is also worth pinning: **Ruby
4.0.6 `x86_64-cosmo` segfaults at VM initialization on Windows 11**
(`[BUG] Segmentation fault at 0x0000000000000000`, right after the
prelude and `encdb.so`/`transdb.so` load; `--version` still works
because it exits before booting the VM), while the 4.0.0 build of the
same tree runs the identical application fine. Both work on Linux, so
this is a payload regression, not an OCRAN one — but it means the
Windows story depends on which `ruby.com` gets bundled.

## Compiler-free packaging: injecting into the interpreter's ZIP store

Everything above launches the application through a **launcher stub**:
an APE compiled with cosmocc that carries the interpreter and the
application as an appended payload and unpacks them into a temporary
directory at every start. That design costs a compiler at packaging time
and ~21 MB of I/O at every launch.

CosmoRuby now runs an embedded `/zip/main.rb`: if the member exists in
the interpreter's own ZIP store, the binary executes it, with the
command line in `ARGV`, `$0`/`__FILE__` = `/zip/main.rb`, `__dir__` =
`/zip`, and `COSMORUBY_NO_ZIP_MAIN=1` as the opt-out. `$LOAD_PATH` is
not touched, so `require_relative` works throughout the archive but
plain `require` does not until something unshifts.

That turns packaging into a file operation: **copy `ruby.com`, append
the application to its ZIP archive**. No cosmocc, no stub, no
extraction.

### Option surface

None added. `--cosmo-ruby <ruby.com>` picks this mode when the given
interpreter supports the hook, and falls back to the launcher stub when
it does not; `--cosmo <toolchain>` next to it means "use the stub", the
reading it already had. Output formats that are not a single binary
(`--output-dir`, `--output-zip`, `--innosetup`, `--macosx-bundle`) keep
the stub too.

Detection reads the binary and looks for the string
`COSMORUBY_NO_ZIP_MAIN`, the name of the opt-out variable, which only a
build implementing the hook contains (`Ocran::CosmoToolchain
.zip_main_support?`). A behavioral probe would mean copying 21 MB,
injecting a script and running it — an order of magnitude more work for
the same answer, and a build that never looks at the variable cannot
produce a false positive. Verified against both builds on hand: the
zip-main build matches, the released fat build does not.

### Layout inside the archive

```
/zip/main.rb              generated bootstrap (the interpreter's entry point)
/zip/ocran/src/...        application sources and packed resources
/zip/ocran/gems/...       pure-Ruby gems (GEM_HOME/GEM_PATH)
/zip/ocran/lib/ruby/...   files packed relative to the Ruby prefix
```

`main.rb` must be at the archive root — that is the interpreter's
contract. Everything else is under `ocran/` because `/zip/bin` and
`/zip/lib/ruby` already belong to the interpreter's own standard
library; a shared namespace would let a packed file shadow part of it
(OCRAN packs gemspecs relative to the Ruby prefix, so the collision is
not hypothetical). The prefix makes it structurally impossible, and
below it the tree is exactly what the extraction mode would have written
to a temp directory, so `Direction` needs no separate layout — only a
different builder (`ZipPayloadBuilder` instead of `StubBuilder`). File
selection, native-gem rejection and payload-provides-gem detection are
untouched.

`ZipPayloadBuilder` also generates `main.rb`, which does what the stub
does after extracting, but from inside the running process: the
environment variables the stub would export are applied by their runtime
equivalents (`RUBYLIB` → `$LOAD_PATH.unshift`, `GEM_HOME`/`GEM_PATH` →
set + `Gem.clear_paths`, `RUBYOPT`'s `-I`/`-r` → replayed), then the
script is run with `Kernel#load` after setting `$PROGRAM_NAME`, so
`__FILE__ == $0` guards fire.

### Writing the archive

`Ocran::ZipWriter`, ~200 lines on top of Zlib. Shelling out to `zip` was
rejected: OCRAN packages on Windows build hosts, where it does not
exist. Adding rubyzip was rejected: OCRAN has one runtime dependency
(fiddle) and this needs the 1989 subset of the format.

Appending means: read the end-of-central-directory record, cut the file
at the start of the central directory, write the new local headers
there, write the **original central directory bytes unchanged** (every
offset in them is still valid, nothing before it moved), then the
central directory records for the new members, then a fresh EOCD. The
executable part of the APE, which lives before all of this, stays
byte-identical. ZIP64 archives and archives with data after the EOCD are
refused rather than corrupted, and a member that would shadow an
existing name is an error.

Two things had to be discovered empirically, by diffing against an
archive the `zip` command produced:

* **UNIX file-type bits are mandatory.** zipos reports the external
  attributes as `st_mode`. With plain permission bits (`0644`) the
  members are found and `File.read` works — but `Kernel#load` refuses
  them, because Ruby checks `S_ISREG`, and `Dir.glob` returns nothing,
  because the directories are not directories. Entries are written with
  `0100644`/`040755`.
* **Parent directory entries must exist.** zipos builds directory
  listings from the members it can see, so `ZipWriter` synthesizes the
  missing intermediate entries.

Proof that Cosmopolitan reads what OCRAN writes is empirical: the
packaged applications below run, and `unzip -t` validates the archive.

### Measured (2026-08-09)

The `logstat` field-test CLI from the section above (8 files, thor +
terminal-table + rainbow + unicode-display_width, cosmopolitan Ruby
4.0.6), average of 10 runs:

| Build | Size | Startup Linux | Startup Windows 11 |
|---|---|---|---|
| ZIP packaging | 21.5 MB | 0.23 s | 0.49 s |
| Launcher stub `--no-lzma` | 22.8 MB | 0.24 s | 1.09 s |
| Launcher stub, LZMA (default) | 11.3 MB | 0.79 s | 1.52 s |

`strace` shows the ZIP build issuing **no** `mkdir` at all; the stub
build creates `/tmp/ocranXXXXXX` with the full tree on every run.
Killing a running application (`kill -9`) leaves a 21 MB directory
behind in stub mode and nothing in ZIP mode — the leak documented above
cannot occur when nothing is written. On Linux with a warm page cache
an uncompressed stub build is nearly as fast as ZIP packaging; the
0.79 s figure that motivated this work is LZMA decompression, and it is
the default. Windows pays both costs.

### Behavior differences (all specific to this mode)

| | Launcher stub | ZIP packaging |
|---|---|---|
| `$0`, `__FILE__`, `__dir__` | temp extraction dir | `/zip/ocran/src/...` |
| `ENV["OCRAN_EXECUTABLE"]` | full path of the `.com` | same (`RbConfig.ruby`, which the interpreter resolves to its own image) |
| Writable application dir | yes (temp) | no — the archive is read-only |
| `--chdir-first` | into the application dir | into the executable's directory (`Dir.chdir("/zip")` returns `ENOTSUP`) |
| Leading `-x` argument | reaches `ARGV` | reaches `ARGV` |
| `RUBYOPT` | exported before launch | only `-I`/`-r` can be replayed |
| Exit code on Windows | correct | correct |
| `--icon`, `--debug-extract` | honored | no effect |

The `__dir__` change is the one that matters for issue #32: an
application that keeps a config file *next to the executable* is
unaffected, because `OCRAN_EXECUTABLE` still means exactly that (the
`logstat` fixture reads its `logstat.yml` this way and works unchanged
on Linux and Windows). An application that (incorrectly) used `__dir__`
for that purpose breaks loudly here instead of quietly picking up a file
from a temp directory.

Two rows of that table used to be interpreter bugs rather than OCRAN
limitations. Both are **fixed** in CosmoRuby (branch `zip-main-fixes`,
2026-08-09), which is why they now read the same in both columns:

1. **Argument parsing.** A binary carrying `/zip/main.rb` no longer
   parses any of its command line: `argv[0]` is dropped and everything
   else reaches `ARGV` verbatim, option-shaped or not, `--` included.
   `app.com --version` is the application's `--version`, not Ruby's.
   Previously Ruby's own flag parser ran first, so `app.com --verbose`
   died with `invalid option --verbose` and only `app.com -- --verbose`
   worked. Interpreter options are still reachable through `RUBYOPT`
   (`-I`, `-r`, `-w`, `-W`, `-d`, `-E`, `--yjit`, `--enable/--disable`)
   and `RUBY_YJIT_ENABLE`; `COSMORUBY_NO_ZIP_MAIN=1` still turns the
   binary back into a plain interpreter.
2. **Exit codes on Windows.** `exit 3` now produces `$LASTEXITCODE` 3.
   Cosmopolitan Libc encodes a POSIX wait status into the Windows
   process exit code (`status << 8`) so that a cosmopolitan parent can
   decode it with `WEXITSTATUS()`; the interpreter now bypasses that for
   the process the user actually started, exactly as the launcher stub
   does for itself (Phase 2.5). `exit`, `exit!`, uncaught exceptions (1)
   and statuses above 255 (narrowed to eight bits, as on Linux) all
   agree with the other platforms.

   That fix has one consequence for the **launcher-stub** mode, and it
   is handled: the stub *is* a cosmopolitan parent — it `fork`s,
   `execv`s `bin/ruby.com` and reads the result with `WEXITSTATUS()`
   (`src/system_utils_posix.c`) — so an honest child status came back
   as death by a signal. Measured on Windows 11 with a stub built before
   the change: `exit 3` → `%ERRORLEVEL%` **131** (128 + 3), `exit 7`
   → **135**. `src/stub.c` therefore sets
   `COSMORUBY_WAIT_STATUS_EXIT=1` for the payload, which asks CosmoRuby
   for the old encoding; with it, 3 is 3 and 7 is 7 again. ZIP packaging
   has no stub and needs nothing.

### Not addressed

* **Windows build hosts.** `--cosmo-ruby` still refuses to run on
  Windows. ZIP packaging removes the cosmocc requirement, which was the
  hard blocker, but the payload query still goes through `/bin/sh` and
  the whole path is untested there. Lifting the restriction is a small,
  separate change.
* **Code signing.** Modifying the APE invalidates any signature it had;
  the artifact would have to be signed after packaging.
* **Compression.** The executable must stay runnable, so it cannot be
  LZMA-compressed as a whole. Individual members are deflated. This is
  the entire size difference against the default stub build.

## Risks / open questions

1. **APE file format vs. appended payload.** An APE is itself a
   PE/shell-script/ZIP polyglot; OCRAN appends its payload after EOF.
   This works on Linux (verified: the EOF signature scan finds the
   payload). On Windows the APE executes as a plain PE, and PE overlays
   are legal, but interaction with the APE ZIP store / `zipos` and with
   `apelink`/`--assimilate` needs explicit testing before trusting it.
2. **Launching Windows Ruby from an APE stub.** The POSIX backend uses
   `fork`+`execv`; Cosmopolitan emulates these on Windows via
   `CreateProcess`, but argument quoting, `.exe` resolution and console
   inheritance must be verified against a real packed `ruby.exe`.
3. **No GUI stub.** `stubw` (`-mwindows` + `MessageBox`) has no cosmo
   equivalent; an APE on Windows is always a console-subsystem binary.
   cosmocc can stay console-only (`stub`), with mingw continuing to
   provide `stubw`.
4. **Code signing.** The Authenticode-aware signature search is compiled
   only under `_WIN32`. A cosmocc stub that gets Authenticode-signed on
   Windows would need that logic ported (guard on the PE magic at run
   time rather than `#ifdef`).
5. **Temp/paths on Windows.** POSIX `GetTempDirectoryPath()` returns
   `$TMPDIR` else `/tmp`; Cosmopolitan translates `/tmp` to the host
   temp dir on Windows, and handles UTF-8→UTF-16 path conversion, but
   8.3 short-name normalization (`ToLongPath`) is a no-op — the
   `$LOADED_FEATURES` dedup issue it works around on mingw would need a
   runtime check if the APE stub ever targets Windows.
6. **Toolchain pinning.** cosmocc releases move fast; CI must pin an
   exact toolchain version.

## Milestones

* **Phase 0 (done)** — `make CC=cosmocc` compiles and links;
  `GetImagePath()` has a `__COSMOPOLITAN__` implementation; smoke test
  passes on Linux; this document.
* **Phase 0.5 (done — runtime build)** — build the stub with cosmocc at
  packaging time: the `--cosmo <toolchain>` command-line option compiles
  `src/` with the user's toolchain and packages with the resulting APE
  stub (console only, `.com` default extension, stub cache in
  `~/.cache/ocran`); end-to-end test `test_cosmo_helloworld` (skipped
  unless a cosmocc toolchain is found via `COSMOCC` or `PATH`) builds
  and runs a packed app on Linux.
* **Phase 1** — CI job building the stub with a pinned cosmocc and
  running the POSIX smoke/test suite against the APE artifact on Linux.
* **Phase 2 — cosmopolitan Ruby payload (done on Linux)** — the
  `--cosmo-ruby <ruby.com>` option packages a cosmopolitan-built Ruby
  APE as the interpreter (see the dedicated section above): stdlib from
  the payload's `/zip` store, pure-Ruby gems via `GEM_PATH`,
  native-extension gems rejected or replaced by the payload's own.
  Gated end-to-end tests (`test_cosmo_ruby_*`, enabled via `COSMOCC` +
  `COSMO_RUBY` env vars) cover hello-world, stdlib (json/yaml) and a
  pure-Ruby gem, each run isolated with `env -i` and asserting
  `x86_64-cosmo`. Cross-OS execution of the produced `.com` remains
  untested (next phase).
* **Phase 2.1 (done) — one option instead of two.** `--cosmo-ruby` no
  longer needs a companion `--cosmo`: the toolchain is discovered from
  `COSMOCC`, `PATH` or a conventional install location, so
  `ocran app.rb --cosmo-ruby ruby.com` is the whole command line.
  `--cosmo <path>` stays as an explicit override (and still works on its
  own, packaging the host Ruby behind an APE stub). Covered by
  `test_cosmo_toolchain_discovery` (precedence and error message),
  `test_cosmo_ruby_infers_toolchain` (option-level inference) and the
  single-option end-to-end test
  `test_cosmo_ruby_helloworld_single_option`.
* **Phase 2.5 (Windows verified; macOS untested)** — Exercise the
  packed APE stub on Windows and macOS runners: payload discovery
  (risk 1), process launch of a real packed Ruby (risk 2), temp-dir
  semantics (risk 5). Verified manually on a Windows 11 x64 VM
  (PowerShell 5.1): a `--cosmo-ruby` hello-world prints the
  `x86_64-cosmo` description, receives argv, propagates the script's
  exit code verbatim to `$LASTEXITCODE`, and cleans up its extraction
  directory; the stdlib (json/yaml) fixture also passes. Two Windows
  bugs were found and fixed along the way (issue #26):
  1. *Temp-dir ambiguity between cosmo runtimes.* Different
     Cosmopolitan releases map the magic `/tmp` prefix to different
     Windows directories (`%TMP%` vs `C:\tmp`), so a literal
     `/tmp/ocranXXXXXX` extraction path created by the stub resolved to
     a *different* directory inside the packed Ruby (built against
     another cosmo version) — `LoadError` for the script. The stub now
     prefers `TMPDIR`, then `TMP`/`TEMP` (which cosmo presents in the
     unambiguous `/C/...` drive-letter form every runtime resolves
     identically) before falling back to `/tmp`.
  2. *Exit-code encoding.* Cosmo encodes the wait status
     (`code << 8`) into the Windows process exit code, so native
     parents saw 1792 instead of 7. The cosmo stub now calls
     `ExitProcess()` directly on Windows with the plain code.
  Not yet automated in CI (manual VM run), and macOS remains untested.
* **Phase 2.6 (done — compiler-free packaging)** — package by injecting
  the application into the interpreter's own ZIP store instead of
  building a launcher stub, when the given cosmopolitan Ruby runs an
  embedded `/zip/main.rb` (see the dedicated section above). No cosmocc,
  no `make`, no extraction: startup 0.79 s → 0.23 s on Linux and
  1.52 s → 0.49 s on Windows, and no temporary directory exists to be
  leaked. No new command-line option: `--cosmo-ruby <ruby.com>` alone
  selects it, `--cosmo <toolchain>` forces the stub. Covered by
  `test_cosmo_zip_main_detection`, `test_cosmo_zip_option_surface`,
  `test_zip_writer_append` (all unconditional) and the gated
  `test_cosmo_zip_end_to_end` / `test_cosmo_zip_gem`, which build the
  application with `COSMOCC` deliberately unset and assert ARGV, exit
  code, packed resources, `OCRAN_EXECUTABLE`, and that nothing is
  written to `TMPDIR`. Verified by hand on Linux and a Windows 11 VM
  with the `logstat` field-test CLI. The two interpreter-side bugs this
  phase documented (leading option-shaped arguments, Windows exit codes)
  are **fixed** in CosmoRuby `zip-main-fixes`; see the behavior-differences
  table above. Windows build hosts are still refused.
* **Phase 3** — Decide the product story: keep cosmocc as a
  cross-platform *console* stub built from POSIX sources (mingw keeps
  `stubw` + signing), or go further and make the APE stub a first-class
  packaging target (requires resolving risks 1–5). The compiler-free
  ZIP packaging of Phase 2.6 is the strongest candidate for the
  recommended cosmo workflow: it is the only one of the three that
  needs no toolchain on the build host and writes nothing on the target.
