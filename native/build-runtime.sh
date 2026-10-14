#!/bin/sh
# Builds the static Windows (x64, UCRT) Ruby runtime used by --native-zip:
# one ruby.exe with every extension and its C library linked in, so a
# packed application loads no DLL other than those that ship with Windows.
#
# Runs on Linux with Debian's gcc-mingw-w64-ucrt64 cross compiler and a host
# Ruby of the same version as the one being built (the cross build needs it
# as baseruby). Every source tarball is checked against native/sources.lock.
#
#   native/build-runtime.sh [build-dir]
#
# Output: a runtime directory for `ocran --native`, <build-dir>/out:
# ocran-runtime.exe, lib/ruby (stdlib and bundled gems), sdk/ (to link in
# more C extensions at packaging time) and runtime.json.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=${1:-$HERE/../../ocran-native-build}
mkdir -p "$BUILD"
BUILD=$(cd "$BUILD" && pwd)
HOST=x86_64-w64-mingw32ucrt
JOBS=${JOBS:-$(nproc)}

SRC=$BUILD/src
DEPS=$BUILD/deps            # static C libraries
WORK=$BUILD/work
OUT=$BUILD/out
mkdir -p "$SRC" "$DEPS" "$WORK" "$OUT"

# pkg-config must only ever see the cross-built dependencies, never the
# build host's own libraries.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" PKG_CONFIG_PATH=

# Reproducibility: fixed timestamps, no build paths in objects, no PE
# link timestamp.
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1767225600}  # 2026-01-01
CFLAGS_COMMON="-O2 -ffile-prefix-map=$BUILD=/build"
LDFLAGS_COMMON="-Wl,--no-insert-timestamp"

lock() { awk -v n="$1" '$1 == n { print $'"$2"' }' "$HERE/sources.lock"; }

fetch() {
  name=$1
  url=$(lock "$name" 4)
  sum=$(lock "$name" 3)
  file=$SRC/$(basename "$url")
  [ -f "$file" ] || curl -fsSL -o "$file" "$url"
  echo "$sum  $file" | sha256sum -c --quiet - || {
    echo "checksum mismatch for $file" >&2; exit 1; }
  rm -rf "$WORK/$name"
  mkdir -p "$WORK/$name"
  tar -xf "$file" -C "$WORK/$name" --strip-components=1
}

build_zlib() {
  fetch zlib
  cd "$WORK/zlib"
  make -f win32/Makefile.gcc PREFIX=$HOST- CFLAGS="$CFLAGS_COMMON" libz.a
  mkdir -p "$DEPS/lib" "$DEPS/include"
  cp libz.a "$DEPS/lib/"
  cp zlib.h zconf.h "$DEPS/include/"
}

build_libffi() {
  fetch libffi
  cd "$WORK/libffi"
  ./configure --host=$HOST --prefix="$DEPS" --disable-shared --enable-static \
    --disable-docs CFLAGS="$CFLAGS_COMMON"
  make -j"$JOBS" && make install
}

build_yaml() {
  fetch yaml
  cd "$WORK/yaml"
  ./configure --host=$HOST --prefix="$DEPS" --disable-shared --enable-static \
    CFLAGS="$CFLAGS_COMMON -DYAML_DECLARE_STATIC"
  make -j"$JOBS" && make install
}

build_openssl() {
  fetch openssl
  cd "$WORK/openssl"
  ./Configure mingw64 no-shared no-tests no-docs no-module \
    --cross-compile-prefix=$HOST- --prefix="$DEPS" --libdir=lib \
    $CFLAGS_COMMON
  # The directories OpenSSL reads certificates, its configuration and
  # engines from are compiled in. Left at the build prefix they would be
  # C:\root\... on the user's machine - a path any user can create. Use
  # OpenSSL's own defaults for Windows, writable only by administrators.
  make -j"$JOBS" build_libs \
    OPENSSLDIR="C:/Program Files/Common Files/SSL" \
    ENGINESDIR="C:/Program Files/OpenSSL/lib/engines-3" \
    MODULESDIR="C:/Program Files/OpenSSL/lib/ossl-modules"
  make install_dev
}

# Bundled gems' extensions are linked as DLLs even in a static build; they
# are added back through the static gem-extension linking step instead.
EXCLUDED_EXTS=readline,pty,syslog,nkf,bigdecimal,bigdecimal-*,debug,debug-*,fiddle,fiddle-*,racc,racc-*,rbs,rbs-*,win32ole,win32ole-*

# Extensions are compiled as if libruby were a DLL: they reach Ruby's
# globals (rb_cObject, rb_eArgError, ...), and some functions, through
# __imp_<name> pointers that only a DLL import table provides. For a static
# link, define those pointers ourselves - one per public libruby symbol,
# which is exactly what the import table would have held.
add_import_shim() {
  $HOST-nm --defined-only "$1" |
    awk '$2 ~ /^[BDRT]$/ && $3 ~ /^(rb_|ruby_|st_|onig|Onig)[A-Za-z0-9_]*$/ { print $3 }' |
    sort -u |
    awk '{ printf "extern char %s;\nvoid *__imp_%s = &%s;\n", $1, $1, $1 }' > ocran_imp_shim.c
  $HOST-gcc $CFLAGS_COMMON -c ocran_imp_shim.c -o ocran_imp_shim.o
  $HOST-ar rs "$1" ocran_imp_shim.o
}

# GNU libiconv (LGPL-2.1) and FreeTDS (LGPL-2.0) are built both static and
# as DLLs: linked in by default, or shipped next to the executable with
# `ocran --native-dll iconv,sybdb` (see LICENSES.md).
build_libiconv() {
  fetch libiconv
  cd "$WORK/libiconv"
  ./configure --host=$HOST --prefix="$DEPS" --enable-static --enable-shared \
    --disable-nls CFLAGS="$CFLAGS_COMMON" LDFLAGS="$LDFLAGS_COMMON -static-libgcc"
  make -j"$JOBS" && make install
}

build_libxml2() {
  fetch libxml2
  cd "$WORK/libxml2"
  ./configure --host=$HOST --prefix="$DEPS" --disable-shared --enable-static \
    --without-python --without-lzma --without-icu --with-zlib="$DEPS" --with-iconv="$DEPS" \
    CFLAGS="$CFLAGS_COMMON" CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib"
  make -j"$JOBS" && make install
}

build_libxslt() {
  fetch libxslt
  cd "$WORK/libxslt"
  ./configure --host=$HOST --prefix="$DEPS" --disable-shared --enable-static \
    --without-python --without-crypto --with-libxml-prefix="$DEPS" \
    CFLAGS="$CFLAGS_COMMON" CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib"
  make -j"$JOBS" && make install
}

build_freetds() {
  fetch freetds
  cd "$WORK/freetds"
  ./configure --host=$HOST --prefix="$DEPS" --enable-static --enable-shared \
    --disable-odbc --disable-apps --disable-server --disable-pool --enable-sspi \
    --with-openssl="$DEPS" --with-libiconv-prefix="$DEPS" \
    CFLAGS="$CFLAGS_COMMON" CPPFLAGS="-I$DEPS/include" \
    LDFLAGS="$LDFLAGS_COMMON -L$DEPS/lib -static-libgcc" \
    OPENSSL_LIBS="-L$DEPS/lib -lssl -lcrypto -lcrypt32 -lws2_32 -lgdi32 -luser32 -ladvapi32" # static OpenSSL
  make -j"$JOBS" && make install
  # libtool links no static library into a DLL, so the DLL (named as in
  # tiny_tds' own Windows builds) is made from the static library: all of
  # it exported, OpenSSL linked in privately, GNU libiconv as its own DLL
  # so that both LGPL libraries stay replaceable.
  rm -f "$DEPS"/lib/libsybdb.la "$DEPS"/lib/libct.la
  $HOST-gcc -shared -o "$DEPS/bin/libsybdb-5.dll" \
    -Wl,--whole-archive "$DEPS/lib/libsybdb.a" -Wl,--no-whole-archive \
    -Wl,--out-implib,"$DEPS/lib/libsybdb.dll.a" -Wl,--exclude-libs,libssl.a:libcrypto.a \
    $LDFLAGS_COMMON -static-libgcc -L"$DEPS/lib" -lssl -lcrypto "$DEPS/lib/libiconv.dll.a" \
    -lsecur32 -lcrypt32 -lws2_32 -lgdi32 -luser32 -ladvapi32
}

build_ruby() {
  fetch ruby
  for p in "$HERE"/patches/ruby-*.patch; do
    patch -d "$WORK/ruby" -p1 --forward < "$p"
  done
  rm -rf "$WORK/ruby-build" && mkdir -p "$WORK/ruby-build"
  cd "$WORK/ruby-build"
  # --host=...mingw32 with the UCRT compiler: configure detects UCRT itself
  # (RUBY_PLATFORM x64-mingw-ucrt), but does not know the ucrt triplet.
  "$WORK/ruby/configure" --host=x86_64-w64-mingw32 --target=x86_64-w64-mingw32 \
    CC=$HOST-gcc CXX=$HOST-g++ AR=$HOST-ar RANLIB=$HOST-ranlib \
    NM=$HOST-nm WINDRES=$HOST-windres STRIP=$HOST-strip \
    --prefix=/ocran-runtime \
    --with-baseruby="$(command -v ruby)" \
    --disable-shared --with-static-linked-ext \
    --disable-install-doc --without-gmp --disable-jit-support \
    --with-opt-dir="$DEPS" --with-openssl-dir="$DEPS" \
    --with-out-ext="$EXCLUDED_EXTS" \
    CPPFLAGS="-DYAML_DECLARE_STATIC -DONIG_EXTERN=extern" \
    CFLAGS="$CFLAGS_COMMON" \
    LDFLAGS="$LDFLAGS_COMMON -static -static-libgcc"
  # RUBY_EXP= : a static ruby.exe normally exports every libruby symbol so
  # extension DLLs can bind to it. This runtime loads no extension DLLs.
  # Without ruby.exp nothing orders libruby before the ruby.exe link, so
  # build it first. ONIG_EXTERN=extern (above): Onigmo otherwise declares
  # its API dllimport, which a static link cannot resolve.
  librubya=$(printf 'print-librubya:\n\t@echo $(LIBRUBY_A)\n' |
    make -s -f GNUmakefile -f - print-librubya 2>/dev/null | tail -1)
  make -j"$JOBS" RUBY_EXP= "$librubya"
  add_import_shim "$librubya"
  make -j"$JOBS" RUBY_EXP=
  # rbinstall copies the DLL import library, which a static build has none
  # of; give it the static archive (it is not part of the runtime).
  librubyimp=$(printf 'print-libruby:\n\t@echo $(LIBRUBY)\n' |
    make -s -f GNUmakefile -f - print-libruby 2>/dev/null | tail -1)
  [ -f "$librubyimp" ] || cp "$librubya" "$librubyimp"
  rm -rf "$OUT" && mkdir -p "$OUT"
  make install-nodoc RUBY_EXP= DESTDIR="$OUT/stage"
}

# Gems bundled with Ruby whose C extensions Ruby's build would only link
# as DLLs (see EXCLUDED_EXTS): built as static archives here.
STATIC_GEM_EXTS="fiddle bigdecimal racc/cparse win32ole"

build_gemexts() {
  cd "$WORK/ruby-build"
  arch=$(basename "$(dirname "$(dirname .ext/include/*/ruby/config.h)")")
  rm -rf "$OUT/exts" && mkdir -p "$OUT/exts"
  for ext in $STATIC_GEM_EXTS; do
    gem=${ext%%/*}
    dir=$(ls -d "$WORK"/ruby/.bundle/gems/"$gem"-*/ext/"$ext")
    ruby --disable=gems -I. -r"./$arch-fake" -I"$WORK/ruby/lib" \
      "$HERE/../lib/ocran/native/build_static_ext.rb" "$WORK/ruby/include" ".ext/include/$arch" \
      "$dir" "$WORK/gemext/$ext" --with-libffi-dir="$DEPS" > "$WORK/gemext.log" 2>&1 ||
      { tail -20 "$WORK/gemext.log"; exit 1; }
    tail -1 "$WORK/gemext.log" > "$OUT/exts/$(echo "$ext" | tr / _).line"
    cat "$OUT/exts/$(echo "$ext" | tr / _).line"
    # rbinstall skipped these gems (their extension was excluded above):
    # install their Ruby code and gemspec the way it would have.
    gemdir=$(ls -d "$WORK"/ruby/.bundle/gems/"$gem"-*)
    name=$(basename "$gemdir")
    gemsroot=$(ls -d "$OUT"/stage/lib/ruby/gems/*)
    rm -rf "$gemsroot/gems/$name" && mkdir -p "$gemsroot/gems/$name"
    cp -a "$gemdir/lib" "$gemsroot/gems/$name/lib"
    cp "$gemdir/$name.gemspec" "$gemsroot/specifications/"
  done
}

# The runtime: the same static link as ruby.exe (every extension and
# encoding), with ocran_main.c in place of Ruby's main.c and the gem
# extensions above added. stage0.rb is compiled in as a C string literal.
# The link inputs are kept as a kit ($OUT/kit) so ocran can re-link the
# runtime with an application's own gem extensions.
build_runtime() {
  cd "$WORK/ruby-build"
  ruby "$HERE/gen-stage0-header.rb" "$HERE/stage0.rb" "$WORK/ruby/stage0.h"
  # Compiled by Ruby's own makefile (same flags as main.c).
  cp "$HERE/ocran_main.c" "$WORK/ruby/ocran_main.c"
  librubya=$(printf 'print-librubya:\n\t@echo $(LIBRUBY_A)\n' |
    make -s -f GNUmakefile -f - print-librubya 2>/dev/null | tail -1)
  make -j"$JOBS" RUBY_EXP= "$librubya"
  add_import_shim "$librubya"
  make RUBY_EXP= MAINOBJ=ocran_main.o ocran_main.o
  ruby "$HERE/make-sdk.rb" . "$WORK/ruby" "$DEPS" "$OUT/sdk" "$OUT"/exts/*.line
  arch=$(basename "$(dirname "$(dirname .ext/include/*/ruby/config.h)")")
  ruby "$HERE/link-runtime.rb" "$OUT/sdk" "$arch" "$OUT/ocran-runtime.exe"
  rm -rf "$OUT/lib" && cp -a "$OUT/stage/lib" "$OUT/lib"
  ruby "$HERE/write-runtime-info.rb" . "$OUT" "$OUT"/exts/*.line
  sha256sum "$OUT/ocran-runtime.exe"
}

# The license texts of everything linked into the runtime (and of the DLL
# builds). ocran packs them into every executable as ocran/licenses/.
build_licenses() {
  L="$OUT/LICENSES"
  rm -rf "$L" && mkdir -p "$L"
  copy() { d="$L/$1"; mkdir -p "$d"; shift; for f in "$@"; do cp "$f" "$d/"; done; }
  copy ruby "$WORK/ruby/BSDL" "$WORK/ruby/COPYING" "$WORK/ruby/LEGAL"
  copy openssl "$WORK/openssl/LICENSE.txt"
  copy libffi "$WORK/libffi/LICENSE"
  copy libyaml "$WORK/yaml/License"
  copy zlib "$WORK/zlib/LICENSE"
  copy libiconv "$WORK/libiconv/COPYING.LIB"
  copy libxml2 "$WORK/libxml2/Copyright"
  copy libxslt "$WORK/libxslt/Copyright"
  copy freetds "$WORK/freetds/COPYING_LIB.txt"
  # Linked in by the compiler: the MinGW-w64 runtime and libgcc (GPL with
  # the GCC Runtime Library Exception).
  copy mingw-w64 /usr/share/doc/mingw-w64-common/copyright
  copy libgcc /usr/share/doc/gcc-mingw-w64-base/copyright
  cat > "$L/README.txt" <<'TXT'
Third-party software in this executable (ocran native runtime, MinGW-w64)

ruby       Ruby (BSD-2-Clause or the Ruby license; LEGAL lists the code
           Ruby itself includes). Bundled and default gems carry their
           own license files inside the archive (lib/ruby/gems/...).
openssl    OpenSSL (Apache-2.0)
libffi     libffi (MIT)
libyaml    libyaml (MIT)
zlib       zlib (zlib license)
libiconv   GNU libiconv (LGPL-2.1-or-later)
libxml2    libxml2 (MIT)
libxslt    libxslt (MIT)
freetds    FreeTDS (LGPL-2.0-or-later)
mingw-w64  MinGW-w64 runtime (various permissive licenses, see file)
libgcc     GCC runtime (GPL-3.0 with the GCC Runtime Library Exception)

GNU libiconv and FreeTDS are under the LGPL. They are linked into the
executable only when an extension uses them (nokogiri: libiconv;
tiny_tds: FreeTDS and libiconv). See ocran's native/LICENSES.md.
TXT
}

for step in ${STEPS:-zlib libffi yaml openssl libiconv libxml2 libxslt freetds ruby gemexts runtime licenses}; do
  echo "==> $step"
  "build_$step"
  cd "$BUILD"
done
