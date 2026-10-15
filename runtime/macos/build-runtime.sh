#!/bin/sh
# Builds the static macOS Ruby runtime used by --static-runtime: Ruby with
# every extension and its C library linked in; the executable links only
# what every Mac has (libSystem, libiconv, CoreFoundation). Native build
# on macOS with clang (Xcode or the Command Line Tools) and a host Ruby
# 4.0 as baseruby. Every source tarball is checked against
# runtime/sources.lock.
#
#   runtime/macos/build-runtime.sh [build-dir]
#
# Output: a runtime directory for `ocran --static-runtime`, <build-dir>/out.
# On macOS ocran links the application archive into the executable as a
# section (sdk/ is required), since appended data would break the code
# signature.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${1:-$HERE/../../ocran-runtime-build-macos}
mkdir -p "$BUILD"
BUILD=$(cd "$BUILD" && pwd)
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
ARCH=$(uname -m) # arm64 or x86_64
export CC=clang
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0}

SRC=$BUILD/src
DEPS=$BUILD/deps
WORK=$BUILD/work
OUT=$BUILD/out
mkdir -p "$SRC" "$DEPS" "$WORK" "$OUT"

# Only the pinned dependencies, never Homebrew's.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" PKG_CONFIG_PATH=
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1767225600}
# Apple's ar, libtool and ranlib write each member's modification time
# into a static library, and ld the objects' times into the executable's
# debug map; with ZERO_AR_DATE they write 0, so that two builds of the same
# sources give the same bytes.
export ZERO_AR_DATE=1
CFLAGS_COMMON="-O2 -ffile-prefix-map=$BUILD=/build"

lock() { awk -v n="$1" '$1 == n { print $'"$2"' }' "$HERE/sources.lock"; }

fetch() {
  name=$1
  url=$(lock "$name" 4)
  sum=$(lock "$name" 3)
  file=$SRC/$(basename "$url")
  [ -f "$file" ] || curl -fsSL -o "$file" "$url"
  echo "$sum  $file" | shasum -a 256 -c --quiet - || {
    echo "checksum mismatch for $file" >&2; exit 1; }
  rm -rf "$WORK/$name"
  mkdir -p "$WORK/$name"
  tar -xf "$file" -C "$WORK/$name" --strip-components=1
}

autotools() { # name configure-args...
  fetch "$1"; cd "$WORK/$1"; shift
  ./configure --prefix="$DEPS" --disable-shared --enable-static \
    CFLAGS="$CFLAGS_COMMON" CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib" "$@"
  make -j"$JOBS" && make install
}

build_zlib() {
  fetch zlib
  cd "$WORK/zlib"
  CFLAGS="$CFLAGS_COMMON" ./configure --static --prefix="$DEPS"
  make -j"$JOBS" libz.a && make install
}

build_libffi() { autotools libffi --disable-docs; }
build_yaml() { autotools yaml; }
build_libxml2() { autotools libxml2 --without-python --without-lzma --without-icu --with-zlib="$DEPS"; }
build_libxslt() { autotools libxslt --without-python --without-crypto --with-libxml-prefix="$DEPS"; }
build_freetds() {
  autotools freetds --disable-odbc --disable-apps --disable-server --disable-pool \
    --with-openssl="$DEPS" OPENSSL_LIBS="-L$DEPS/lib -lssl -lcrypto"
  rm -f "$DEPS"/lib/*.la
}

build_openssl() {
  fetch openssl
  cd "$WORK/openssl"
  ./Configure "darwin64-$ARCH-cc" no-shared no-tests no-docs no-module \
    --prefix="$DEPS" --libdir=lib $CFLAGS_COMMON
  # Root-owned directories; certificates come from /etc/ssl/cert.pem
  # (patches/ruby-openssl-system-store.patch).
  make -j"$JOBS" build_libs OPENSSLDIR=/private/etc/ssl \
    ENGINESDIR=/usr/lib/ossl-engines MODULESDIR=/usr/lib/ossl-modules
  make install_dev
}

EXCLUDED_EXTS=-test-/*,readline,nkf,bigdecimal,bigdecimal-*,debug,debug-*,fiddle,fiddle-*,racc,racc-*,rbs,rbs-*,win32ole,win32ole-*,syslog,syslog-*

build_ruby() {
  fetch ruby
  for p in "$HERE"/patches/ruby-*.patch; do
    patch -d "$WORK/ruby" -p1 --forward < "$p"
  done
  rm -rf "$WORK/ruby-build" && mkdir -p "$WORK/ruby-build"
  cd "$WORK/ruby-build"
  "$WORK/ruby/configure" --prefix=/ocran-runtime \
    --with-baseruby="$(command -v ruby)" \
    --disable-shared --with-static-linked-ext \
    --disable-install-doc --without-gmp --disable-jit-support \
    --with-opt-dir="$DEPS" --with-openssl-dir="$DEPS" --with-libyaml-dir="$DEPS" \
    --with-libffi-dir="$DEPS" --with-zlib-dir="$DEPS" \
    --with-out-ext="$EXCLUDED_EXTS" \
    CFLAGS="$CFLAGS_COMMON"
  make -j"$JOBS"
  rm -rf "$OUT" && mkdir -p "$OUT"
  make install-nodoc DESTDIR="$OUT/stage"
  mv "$OUT/stage/ocran-runtime"/* "$OUT/stage/" && rmdir "$OUT/stage/ocran-runtime"
}

STATIC_GEM_EXTS="fiddle bigdecimal racc/cparse"

# As in the cross builds, the host Ruby poses as the runtime through Ruby's
# <arch>-fake.rb, which also points mkmf at the build directory's static
# libruby (the SDK does the same at packaging time).
build_gemexts() {
  cd "$WORK/ruby-build"
  arch=$(basename "$(dirname "$(dirname .ext/include/*/ruby/config.h)")")
  make "$arch-fake.rb"
  rm -rf "$OUT/exts" && mkdir -p "$OUT/exts"
  for ext in $STATIC_GEM_EXTS; do
    gem=${ext%%/*}
    dir=$(ls -d "$WORK"/ruby/.bundle/gems/"$gem"-*/ext/"$ext")
    ruby --disable=gems -I. -r"./$arch-fake" -I"$WORK/ruby/lib" \
      "$HERE/../lib/ocran/static_runtime/build_static_ext.rb" "$WORK/ruby/include" ".ext/include/$arch" \
      "$dir" "$WORK/gemext/$ext" --with-libffi-dir="$DEPS" > "$WORK/gemext.log" 2>&1 ||
      { tail -30 "$WORK/gemext.log"; exit 1; }
    tail -1 "$WORK/gemext.log" > "$OUT/exts/$(echo "$ext" | tr / _).line"
    cat "$OUT/exts/$(echo "$ext" | tr / _).line"
    gemdir=$(ls -d "$WORK"/ruby/.bundle/gems/"$gem"-*)
    name=$(basename "$gemdir")
    gemsroot=$(ls -d "$OUT"/stage/lib/ruby/gems/*)
    rm -rf "$gemsroot/gems/$name" && mkdir -p "$gemsroot/gems/$name"
    cp -R "$gemdir/lib" "$gemsroot/gems/$name/lib"
    cp "$gemdir/$name.gemspec" "$gemsroot/specifications/"
  done
}

build_runtime() {
  cd "$WORK/ruby-build"
  ruby "$HERE/gen-stage0-header.rb" "$HERE/stage0.rb" "$WORK/ruby/stage0.h"
  cp "$HERE/ocran_main.c" "$WORK/ruby/ocran_main.c"
  make MAINOBJ=ocran_main.o ocran_main.o
  ruby "$HERE/make-sdk.rb" . "$WORK/ruby" "$DEPS" "$OUT/sdk" "$OUT"/exts/*.line
  arch=$(basename "$(dirname "$(dirname .ext/include/*/ruby/config.h)")")
  # Linked without an application archive: ocran links every executable
  # anew with its archive; this one only shows the link works.
  ruby "$HERE/link-runtime.rb" "$OUT/sdk" "$arch" "$OUT/ocran-runtime"
  rm -rf "$OUT/lib" && cp -R "$OUT/stage/lib" "$OUT/lib"
  ruby "$HERE/write-runtime-info.rb" . "$OUT" "$OUT"/exts/*.line
  shasum -a 256 "$OUT/ocran-runtime"
}

build_licenses() {
  L="$OUT/LICENSES"
  rm -rf "$L" && mkdir -p "$L"
  copy() { d="$L/$1"; mkdir -p "$d"; shift; for f in "$@"; do cp "$f" "$d/"; done; }
  copy ruby "$WORK/ruby/BSDL" "$WORK/ruby/COPYING" "$WORK/ruby/LEGAL"
  copy openssl "$WORK/openssl/LICENSE.txt"
  copy libffi "$WORK/libffi/LICENSE"
  copy libyaml "$WORK/yaml/License"
  copy zlib "$WORK/zlib/LICENSE"
  copy libxml2 "$WORK/libxml2/Copyright"
  copy libxslt "$WORK/libxslt/Copyright"
  copy freetds "$WORK/freetds/COPYING_LIB.txt"
  cat > "$L/README.txt" <<'TXT'
Third-party software in this executable (ocran static runtime, macOS)

ruby       Ruby (BSD-2-Clause or the Ruby license; LEGAL lists the code
           Ruby itself includes). Bundled and default gems carry their
           own license files inside the archive (lib/ruby/gems/...).
openssl    OpenSSL (Apache-2.0)
libffi     libffi (MIT)
libyaml    libyaml (MIT)
zlib       zlib (zlib license)
libxml2    libxml2 (MIT)
libxslt    libxslt (MIT)
freetds    FreeTDS (LGPL-2.0-or-later)

The executable also uses system libraries of macOS (libSystem, libiconv,
CoreFoundation), which are not part of it. FreeTDS is under the LGPL and
linked in only when an extension uses it (tiny_tds). See ocran's
runtime/LICENSES.md.
TXT
}

for step in ${STEPS:-zlib libffi yaml openssl libxml2 libxslt freetds ruby gemexts runtime licenses}; do
  echo "==> $step"
  "build_$step"
  cd "$BUILD"
done
