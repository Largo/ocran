# Compiling the OCRAN stub with cosmocc (Cosmopolitan Libc)

Status: **experimental — the POSIX stub already compiles and passes an
end-to-end smoke test with cosmocc**. Tracking issue:
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
* **Phase 2** — Exercise the packed APE stub on Windows and macOS
  runners: payload discovery (risk 1), process launch of a real packed
  Ruby (risk 2), temp-dir semantics (risk 5).
* **Phase 3** — Decide the product story: keep cosmocc as a
  cross-platform *console* stub built from POSIX sources (mingw keeps
  `stubw` + signing), or go further and make the APE stub a first-class
  packaging target (requires resolving risks 1–5).
