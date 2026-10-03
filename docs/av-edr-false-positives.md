# Reducing antivirus / EDR false positives

OCRAN-built executables are sometimes flagged by antivirus (AV) products or
endpoint detection and response (EDR) agents even though they are completely
benign. This is a *false positive*: the detection fires on structural and
behavioural traits that OCRAN shares with real malware packers, not on
anything malicious.

This document explains **why** it happens and **what you can do about it**,
ordered from highest to lowest impact. None of this is about evading
detection — it is about making a legitimate program look like the ordinary,
identifiable product it is, so heuristics and reputation systems stop
guessing. The PE resource options below (`--set-version-string` and the
others) exist for exactly this purpose.

## Why an OCRAN exe looks suspicious

A generic malware packer does three things that OCRAN also does by design:

1. Appends an opaque, often **compressed** (high-entropy) blob to a small
   native stub.
2. At startup, **writes files out to a temporary directory and executes
   them** (OCRAN extracts the Ruby interpreter and your scripts to `%TEMP%`).
3. Ships **unsigned**, with **no version metadata**, so there is nothing to
   identify the publisher or the product.

Any one of these is a weak signal; together, and with no offsetting
reputation, they are enough for a heuristic verdict.

## The levers (highest impact first)

### 1. Code-sign the executable (biggest single win)

A valid Authenticode signature from a certificate that has built up
reputation is by far the most effective measure. With an **EV code-signing
certificate**, Microsoft SmartScreen trusts the binary almost immediately;
with a standard OV certificate, reputation accrues as copies run in the
field.

OCRAN already supports signing: build the exe, then sign it with your normal
toolchain (`signtool`, `osslsigncode`, …). OCRAN clears invalid PE security
directory entries from the stub so the signature applies cleanly, and the
runtime understands signed executables.

> **Order matters.** Sign *after* OCRAN has built the exe. OCRAN writes all
> PE resources (icon, version info, manifest) at build time via
> `BeginUpdateResource`/`EndUpdateResource`, which rewrites the whole PE; a
> signature applied before that would be invalidated. Sign last.

### 2. Stamp a version resource

An executable with **no `VS_VERSIONINFO` resource** is a classic packer
fingerprint. Giving each application its own real metadata — CompanyName,
ProductName, FileVersion, LegalCopyright — makes it look like normal
commercial software and gives reputation systems a stable identity to track.

```sh
ocran myapp.rb \
  --set-version-string CompanyName     "Example GmbH" \
  --set-version-string ProductName     "My Cool App" \
  --set-version-string FileDescription "My Cool App" \
  --set-version-string LegalCopyright  "(C) 2026 Example GmbH" \
  --set-file-version    1.4.0.0 \
  --set-product-version 1.4.0.0
```

`--set-version-string <key> <value>` sets any StringFileInfo key (CompanyName,
FileDescription, ProductName, LegalCopyright, OriginalFilename, …).
`--set-file-version` / `--set-product-version` set the numeric
`VS_FIXEDFILEINFO` fields (and the matching string entries). Short aliases
`--version-string`, `--file-version`, `--product-version` exist.

These options are **opt-in**: with none of them given, OCRAN writes no version
resource and the build is unchanged. Use your **own** company and product
strings — do **not** copy another vendor's metadata, and do **not** share one
generic identity across unrelated programs, which invites *cluster*
detections where one bad sample taints every build that looks like it.

### 3. Set a distinct icon

`--icon myapp.ico` has a similar, smaller effect: a unique icon contributes
to a distinct, trackable identity. The default icon is shared by every OCRAN
build, which is the opposite of what you want.

### 4. Keep the manifest conservative — don't ask for admin without cause

OCRAN's stub manifest requests `asInvoker` (no elevation). Requesting
`requireAdministrator` makes the OS show a UAC prompt and makes heuristics
more suspicious, so only raise the level when the application genuinely needs
it:

```sh
ocran myapp.rb --set-requested-execution-level asInvoker   # default, recommended
```

Valid levels are `asInvoker`, `highestAvailable`, `requireAdministrator`
(alias `--uac-level`). To supply a complete custom manifest instead, use
`--application-manifest myapp.manifest` (alias `--manifest`); it replaces the
stub's compiled-in manifest rather than adding a second one. Keep the UTF-8
`activeCodePage` and `supportedOS` entries from the shipped template.

### 5. Avoid executing from `%TEMP%` where you can

The extract-to-temp-then-execute pattern is the most malware-like *behaviour*
an EDR sees at runtime. Two mitigations:

- `--chdir-first` together with an installer (e.g. Inno Setup) installs the
  application next to the executable and runs it in place, rather than
  unpacking into `%TEMP%` on every launch. The resource options above apply
  to the installer's wrapper exe too, so the installed launcher is identified
  just like the standalone exe.
- `--chdir-exe-dir` keeps the working directory next to the exe.

A properly installed, signed application triggers far fewer behavioural
heuristics than a single self-extracting exe run from a download folder.

### 6. Consider entropy vs. size (`--no-lzma`)

LZMA compression (the default) raises the file's entropy, which some
heuristics read as "packed/encrypted". `--no-lzma` produces a larger but
lower-entropy file. This is a minor lever and a real trade-off; it is only
worth touching if a specific engine is flagging on entropy and the other
measures above are already in place. (`--no-lzma` is required anyway when
building an Inno Setup installer.)

## If you are still flagged

- **Submit a false-positive report** to the vendor (Microsoft, and whichever
  engines flag you on VirusTotal). Signed binaries with real metadata are
  processed far more readily.
- **Give it reputation.** Signed binaries from a consistent publisher
  accumulate trust as they are seen in the wild; brand-new unsigned binaries
  have none.
- **Don't chase evasion.** Techniques aimed at hiding from AV make the
  reputation problem worse and are exactly what the heuristics are built to
  catch. The durable fix is identity (signing + metadata) and benign
  behaviour (install, don't self-extract-and-run).

## Summary

| Lever | Impact | How |
|-------|--------|-----|
| Code signing (EV best) | Highest | Sign the built exe with your toolchain, last |
| Version resource | High | `--set-version-string`, `--set-file-version`, … |
| Distinct icon | Medium | `--icon myapp.ico` |
| Conservative manifest | Medium | Keep `asInvoker`; raise UAC only if required |
| Install instead of temp-extract | Medium | `--chdir-first` + Inno Setup installer |
| Lower entropy | Low | `--no-lzma` (trade-off) |
