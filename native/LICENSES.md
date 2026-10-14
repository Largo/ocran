# Licenses and static linking (`--native`)

An executable built with `--native` is **statically linked**: Ruby and the
C libraries below are compiled into the one `.exe`, together with your
application and the gems it uses. That is what lets it run without
extracting anything, and it is also what licenses look at: distributing
the executable means distributing all of these components, combined.

This page lists what is in a native executable and what the licenses ask
of whoever distributes it. **It is not legal advice.** If you distribute
software commercially, or the obligations below are unclear for your
case, ask someone qualified.

## What is linked in

| Component | License | Linked in |
|---|---|---|
| Ruby | BSD-2-Clause or the Ruby license (see `LEGAL` for code Ruby includes) | always |
| Default and bundled gems (json, psych, openssl, fiddle, bigdecimal, ...) | Ruby/BSD-2-Clause, MIT and others; each gem's license file is in the archive | the ones your application uses |
| OpenSSL 3 | Apache-2.0 | always |
| libffi | MIT | always |
| libyaml | MIT | always |
| zlib | zlib | always |
| libxml2, libxslt | MIT | when an extension uses them (nokogiri) |
| **GNU libiconv** | **LGPL-2.1-or-later** | when an extension uses it (nokogiri, tiny_tds) |
| **FreeTDS** | **LGPL-2.0-or-later** | when an extension uses it (tiny_tds) |
| MinGW-w64 runtime (MinGW build) | permissive (public domain, ZPL, MIT) | always |
| libgcc (MinGW build) | GPL-3.0 with the GCC Runtime Library Exception | always |
| Microsoft C runtime (mswin build, `-MT`) | Visual Studio license, which permits static linking into your program | always |
| Your gems' C extensions | their own licenses | when used |

The exact versions are in `native/sources.lock` (MinGW) and
`native/mswin/vcpkg.json` (mswin).

## What OCRAN does for you

* Every native executable contains the license texts of the runtime's
  components as `ocran/licenses/` inside its archive
  (`unzip -l app.exe "ocran/licenses/*"`), and the license files of the
  gems it packs. That covers the "include the copyright notice and license"
  condition of the permissive licenses (MIT, BSD, zlib, Apache-2.0) for
  the executable itself. It is good practice to also mention them in your
  documentation or an About box.
* `ocran/manifest.sha256` inside the archive lists every packed file with
  its hash, so you can always tell exactly what you shipped.

## The LGPL libraries (GNU libiconv, FreeTDS)

The LGPL allows these libraries in proprietary programs, on conditions.
For a program that contains an LGPL library, they include (LGPL-2.1
section 6, simplified):

1. **Say so and include the license** (OCRAN packs it).
2. **Provide the library's source code**, or a written offer for it. The
   sources ocran's runtime is built from are pinned with their SHA-256 in
   `native/sources.lock`.
3. **Let the user replace the library with a modified version** and still
   run your program.

Condition 3 is the one static linking makes hard: the library is inside
your executable. There are two ways to meet it:

* **Ship the LGPL libraries as DLLs next to the executable** - which
  `--native-dll` does:

  ```
  ocran app.rb --native RUNTIME --native-dll iconv,sybdb
  ```

  The executable is then linked against `libiconv-2.dll` and
  `libsybdb-5.dll`, which OCRAN copies next to it (with the DLLs they need
  in turn). A user can replace those files. This is the usual way, and the
  simplest to explain. The executable is then no longer a single file:
  ship the DLLs with it, and keep them in the same directory.
* **Provide the means to relink**: the object code of your program in a
  form that can be linked again with a modified library. With `--native`
  that is the application archive inside the executable plus the runtime's
  SDK (`sdk/`), which is what OCRAN links with - but making that usable
  and documented for your users is your responsibility, and it is more
  work than the DLL route.

Only applications that use these libraries are affected: an application
without nokogiri or tiny_tds contains neither.

## Other things to check

* **GPL-licensed gems.** If your application uses a gem under the GPL, the
  GPL applies to the program you distribute as a whole, static linking or
  not. Check the licenses of your gems (`gem specification <name>
  license`).
* **Your own license terms** must not forbid what the LGPL requires
  (reverse engineering for debugging modifications of the LGPL library,
  LGPL-2.1 section 6).
* **Code signing and the libraries' names.** Shipping DLLs changes nothing
  about signing: sign the executable and the DLLs.
