#!/bin/sh
# Builds the static Linux (x86_64, musl) Ruby runtime used by
# --static-runtime: one fully static ELF executable with every extension and
# its C library linked in. It depends on nothing on the system, not even
# the C library, so it runs on any x86_64 Linux distribution.
#
# Runs on Debian/Ubuntu with musl-tools (musl-gcc) and linux-libc-dev, and
# a host Ruby of the same minor version as the one being built (the build
# is a cross build, which needs it as baseruby). Every source tarball is
# checked against runtime/sources.lock.
#
#   runtime/linux/build-runtime.sh [build-dir]
#
# Output: a runtime directory for `ocran --static-runtime`, <build-dir>/out:
# ocran-runtime, lib/ruby (stdlib and bundled gems), sdk/ (to link in more
# C extensions at packaging time), LICENSES/ and runtime.json.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${1:-$HERE/../../ocran-runtime-build-linux}
mkdir -p "$BUILD"
BUILD=$(cd "$BUILD" && pwd)
HOST=x86_64-linux-musl
JOBS=${JOBS:-$(nproc)}
export CC=musl-gcc

SRC=$BUILD/src
DEPS=$BUILD/deps
WORK=$BUILD/work
OUT=$BUILD/out
mkdir -p "$SRC" "$DEPS" "$WORK" "$OUT"

export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" PKG_CONFIG_PATH=
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1767225600}

# musl-gcc sees only musl's headers; the Linux kernel headers (linux/,
# asm/, asm-generic/) come from linux-libc-dev.
KHDR=$BUILD/kernel-headers
mkdir -p "$KHDR"
for d in linux asm-generic mtd; do ln -sfn "/usr/include/$d" "$KHDR/$d"; done
ln -sfn "/usr/include/$(uname -m)-linux-gnu/asm" "$KHDR/asm"
CFLAGS_COMMON="-O2 -ffile-prefix-map=$BUILD=/build"
CPPFLAGS_COMMON="-isystem $KHDR"

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

autotools() { # name configure-args...
  fetch "$1"; cd "$WORK/$1"; shift
  ./configure --host=$HOST --prefix="$DEPS" --disable-shared --enable-static \
    CFLAGS="$CFLAGS_COMMON" CPPFLAGS="$CPPFLAGS_COMMON -I$DEPS/include" LDFLAGS="-L$DEPS/lib" "$@"
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
  ./Configure linux-x86_64 no-shared no-tests no-docs no-module no-afalgeng \
    --prefix="$DEPS" --libdir=lib $CFLAGS_COMMON $CPPFLAGS_COMMON
  # The compiled-in directories: where Debian keeps OpenSSL's, root-owned
  # everywhere. Certificates come from the system's CA bundle wherever it
  # is (patches/ruby-openssl-system-store.patch).
  make -j"$JOBS" build_libs OPENSSLDIR=/usr/lib/ssl \
    ENGINESDIR=/usr/lib/ssl/engines-3 MODULESDIR=/usr/lib/ssl/ossl-modules
  make install_dev
}

# Bundled gems' extensions are linked as shared objects even in a static
# build; they are added back through the static gem-extension step.
EXCLUDED_EXTS=-test-/*,readline,nkf,bigdecimal,bigdecimal-*,debug,debug-*,fiddle,fiddle-*,racc,racc-*,rbs,rbs-*,win32ole,win32ole-*,syslog,syslog-*

build_ruby() {
  fetch ruby
  for p in "$HERE"/patches/ruby-*.patch; do
    patch -d "$WORK/ruby" -p1 --forward < "$p"
  done
  rm -rf "$WORK/ruby-build" && mkdir -p "$WORK/ruby-build"
  cd "$WORK/ruby-build"
  "$WORK/ruby/configure" --host=$HOST --build="$(uname -m)-pc-linux-gnu" \
    CC=musl-gcc AR=ar RANLIB=ranlib NM=nm STRIP=strip \
    --prefix=/ocran-runtime \
    --with-baseruby="$(command -v ruby)" \
    --disable-shared --with-static-linked-ext \
    --disable-install-doc --without-gmp --disable-jit-support \
    --with-opt-dir="$DEPS" --with-openssl-dir="$DEPS" \
    --with-out-ext="$EXCLUDED_EXTS" \
    CPPFLAGS="$CPPFLAGS_COMMON -DYAML_DECLARE_STATIC" \
    CFLAGS="$CFLAGS_COMMON" \
    LDFLAGS="-static" \
    ac_cv_func_crypt_r=no # musl declares struct crypt_data only for _GNU_SOURCE
  make -j"$JOBS"
  rm -rf "$OUT" && mkdir -p "$OUT"
  make install-nodoc DESTDIR="$OUT/stage"
  # DESTDIR keeps the prefix; the runtime directory has no prefix.
  mv "$OUT/stage/ocran-runtime"/* "$OUT/stage/" && rmdir "$OUT/stage/ocran-runtime"
}

STATIC_GEM_EXTS="fiddle bigdecimal racc/cparse"

build_gemexts() {
  cd "$WORK/ruby-build"
  arch=$(basename "$(dirname "$(dirname .ext/include/*/ruby/config.h)")")
  rm -rf "$OUT/exts" && mkdir -p "$OUT/exts"
  for ext in $STATIC_GEM_EXTS; do
    gem=${ext%%/*}
    dir=$(ls -d "$WORK"/ruby/.bundle/gems/"$gem"-*/ext/"$ext")
    ruby --disable=gems -I. -r"./$arch-fake" -I"$WORK/ruby/lib" \
      "$HERE/../lib/ocran/static_runtime/build_static_ext.rb" "$WORK/ruby/include" ".ext/include/$arch" \
      "$dir" "$WORK/gemext/$ext" --with-libffi-dir="$DEPS" > "$WORK/gemext.log" 2>&1 ||
      { tail -20 "$WORK/gemext.log"; exit 1; }
    tail -1 "$WORK/gemext.log" > "$OUT/exts/$(echo "$ext" | tr / _).line"
    cat "$OUT/exts/$(echo "$ext" | tr / _).line"
    gemdir=$(ls -d "$WORK"/ruby/.bundle/gems/"$gem"-*)
    name=$(basename "$gemdir")
    gemsroot=$(ls -d "$OUT"/stage/lib/ruby/gems/*)
    rm -rf "$gemsroot/gems/$name" && mkdir -p "$gemsroot/gems/$name"
    cp -a "$gemdir/lib" "$gemsroot/gems/$name/lib"
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
  ruby "$HERE/link-runtime.rb" "$OUT/sdk" "$arch" "$OUT/ocran-runtime"
  rm -rf "$OUT/lib" && cp -a "$OUT/stage/lib" "$OUT/lib"
  ruby "$HERE/write-runtime-info.rb" . "$OUT" "$OUT"/exts/*.line
  sha256sum "$OUT/ocran-runtime"
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
  copy musl /usr/share/doc/musl/copyright
  copy libgcc "/usr/share/doc/gcc-$(gcc -dumpversion | cut -d. -f1)-base/copyright"
  cat > "$L/README.txt" <<'TXT'
Third-party software in this executable (ocran static runtime, Linux/musl)

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
musl       musl libc (MIT)
libgcc     GCC runtime (GPL-3.0 with the GCC Runtime Library Exception)

FreeTDS is under the LGPL. It is linked into the executable only when an
extension uses it (tiny_tds). See ocran's runtime/LICENSES.md.
TXT
}

for step in ${STEPS:-zlib libffi yaml openssl libxml2 libxslt freetds ruby gemexts runtime licenses}; do
  echo "==> $step"
  "build_$step"
  cd "$BUILD"
done
