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

* **Build-at-packaging-time (implemented):** `ocran script.rb --cosmo
  <path-to-toolchain>` compiles the stub sources with the given cosmocc
  during the packaging run and packages the app with the fresh APE stub
  (default output extension `.com`). Implementation:
  `lib/ocran/cosmo_toolchain.rb` (path resolution, compile via `make -C
  src stub CC=cosmocc` in a temp copy of `src/`, compiler output
  surfaced on failure, results cached in `~/.cache/ocran` keyed on
  toolchain + source hash). The binary platform gems now ship `src/` so
  this works from an installed gem, not just a checkout.
* Manual: `make -C src CC=cosmocc` with `cosmocc` on `PATH`
  (single ~440 MB zip from <https://cosmo.zip/pub/cosmocc/cosmocc.zip>).
* CI sketch (phase 1): a Linux job that caches the pinned cosmocc zip,
  builds `src` with `CC=cosmocc`, and runs the existing POSIX test path
  against the APE stub. The mingw/RubyInstaller jobs stay untouched —
  cosmocc is an *additional* backend, not a replacement.

## Cosmopolitan Ruby as the payload (`--cosmo-ruby`)

Phase 2 of the effort: `ocran app.rb --cosmo <toolchain> --cosmo-ruby
<ruby.com>` packages a cosmopolitan-built Ruby APE as the bundled
interpreter, so the produced `.com` contains **both** an APE stub and an
APE Ruby — no host-native code at all. Verified end-to-end on Linux
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

* Console-only, POSIX build hosts only (inherited from `--cosmo`).
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
with `--cosmo --cosmo-ruby` and the **same 10.9 MB `.com`** run on Linux
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
  pure startup — the analysis itself is ~25 ms). A persistent install
  directory (`--chdir-first`) is the obvious mitigation for
  latency-sensitive uses.

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
  equivalent `| head -2`. A stale-directory sweep at startup, or
  extraction into a directory keyed on the executable's hash, would
  bound the damage.
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

The cosmopolitan Ruby payload itself is also worth pinning: **Ruby
4.0.6 `x86_64-cosmo` segfaults at VM initialization on Windows 11**
(`[BUG] Segmentation fault at 0x0000000000000000`, right after the
prelude and `encdb.so`/`transdb.so` load; `--version` still works
because it exits before booting the VM), while the 4.0.0 build of the
same tree runs the identical application fine. Both work on Linux, so
this is a payload regression, not an OCRAN one — but it means the
Windows story depends on which `ruby.com` gets bundled.

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
* **Phase 2.5 (Windows verified; macOS untested)** — Exercise the
  packed APE stub on Windows and macOS runners: payload discovery
  (risk 1), process launch of a real packed Ruby (risk 2), temp-dir
  semantics (risk 5). Verified manually on a Windows 11 x64 VM
  (PowerShell 5.1): a `--cosmo --cosmo-ruby` hello-world prints the
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
* **Phase 3** — Decide the product story: keep cosmocc as a
  cross-platform *console* stub built from POSIX sources (mingw keeps
  `stubw` + signing), or go further and make the APE stub a first-class
  packaging target (requires resolving risks 1–5).
