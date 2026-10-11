#!/usr/bin/env bash
#
# Builds statically linked hb-shape/hb-info/hb-subset/hb-vector/hb-raster from
# the HarfBuzz sources.
#
#   bash scripts/build-harfbuzz.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# Every target is built from source: HarfBuzz publishes Windows binaries only,
# and they are linked dynamically and without FreeType.
#
# The tools are built with FreeType, so that `--font-funcs=ft` and
# `--face-loader=ft` are available next to `ot`, and FreeType is built with
# zlib, brotli and libpng, so that it opens WOFF and WOFF2 files and loads PNG
# glyphs. CoreText, DirectWrite, GDI, ICU and Graphite are left out: every
# target has the same shapers and the same font functions.
#
# The command-line parsing of the tools is GLib's, which is therefore linked
# statically too. GLib, libffi, PCRE2 and FreeType are the versions the meson
# wraps of the HarfBuzz release pin, with their checksums, and are built as
# subprojects of HarfBuzz. zlib, brotli and libpng are the versions ffmpeg and
# the libjxl tools are built with; this script has its own prefix, as
# scripts/build-libjxl.sh does.
#
# hb-view is not built: it needs cairo.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# Dependency versions come from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
for name in ZLIB_VERSION BROTLI_VERSION LIBPNG_VERSION HARFBUZZ_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
PREFIX="$WORKDIR/harfbuzz-deps"
SRCDIR="$WORKDIR/harfbuzz-src"
STAMPDIR="$PREFIX/.stamps"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS="hb-shape hb-info hb-subset hb-vector hb-raster"

mkdir -p "$PREFIX" "$SRCDIR" "$STAMPDIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

msg() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

job_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.logicalcpu
  else
    echo 2
  fi
}
JOBS="$(job_count)"

# Download with retries, then verify the archive really is an archive.
download() {
  url="$1"
  out="$2"
  attempt=1
  while [ "$attempt" -le 5 ]; do
    rm -f "$out"
    if curl -fsSL --retry 2 --connect-timeout 30 "$url" -o "$out"; then
      case "$out" in
        *.tar.gz|*.tgz) tar -tzf "$out" >/dev/null 2>&1 && return 0 ;;
        *.tar.xz)       tar -tJf "$out" >/dev/null 2>&1 && return 0 ;;
        *)              [ -s "$out" ] && return 0 ;;
      esac
      echo "downloaded file is not a valid archive: $url" >&2
    fi
    echo "download attempt $attempt failed: $url" >&2
    attempt=$((attempt + 1))
    sleep $((2 * attempt))
  done
  echo "failed to download $url after 5 attempts" >&2
  return 1
}

# Fetch + extract into $SRCDIR.
fetch() {
  name="$1"; url="$2"; archive="$3"; dir="$4"
  if [ ! -d "$SRCDIR/$dir" ]; then
    msg "fetching $name"
    download "$url" "$SRCDIR/$archive"
    ( cd "$SRCDIR" && tar -xf "$archive" )
  fi
  [ -d "$SRCDIR/$dir" ] || { echo "expected source directory $dir not found" >&2; exit 1; }
}

stamp_done() { [ -f "$STAMPDIR/$1" ]; }
stamp_mark() { : > "$STAMPDIR/$1"; }

# Full-static builds must never see a shared library. Delete any that a
# dependency installs despite being asked for static-only.
purge_shared_libs() {
  rm -f "$PREFIX"/lib/*.so "$PREFIX"/lib/*.so.* "$PREFIX"/lib/*.dylib \
        "$PREFIX"/lib/*.dll.a "$PREFIX"/bin/*.dll 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Target configuration
# ---------------------------------------------------------------------------

EXE=""
CMAKE_CROSS_ARGS=""
MESON_TARGET_ARGS=""
STRIP="strip"

case "$TARGET" in
  linux-*)
    # Same compiler as the ffmpeg build.
    export CC=clang CXX=clang++
    MESON_TARGET_ARGS="-Dc_link_args=-static -Dcpp_link_args=-static"
    ;;
  win-x64)
    EXE=".exe"
    [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
    export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
    MINGW_TRIPLE="x86_64-w64-mingw32"
    export MINGW_TRIPLE
    CMAKE_CROSS_ARGS="-DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/mingw-toolchain.cmake -DMINGW_TRIPLE=$MINGW_TRIPLE"
    STRIP="$MINGW_TRIPLE-strip"
    # The cross file is written below, once the sources are there.
    ;;
  osx-arm64)
    # macOS has no static libSystem: the goal here is "no non-system dylibs".
    STRIP="strip -x"
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    ;;
esac

# pkg-config must see the prefix and nothing else, so that Homebrew cannot leak
# a .dylib into the link.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
# Everything in the prefix is a static library, whose private dependencies are
# needed too: libbrotlidec.a does not link without libbrotlicommon.a. meson's
# prefer_static option is not used for that: it also asks for a static iconv,
# which macOS does not have. The cross file does the same for win-x64.
export PKG_CONFIG="pkg-config --static"

CMAKE_COMMON="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=OFF"

# run_cmake <name> <source dir> [extra cmake args...]
run_cmake() {
  name="$1"; src="$2"; shift 2
  msg "building $name"
  # shellcheck disable=SC2086
  cmake -S "$src" -B "$WORKDIR/build-harfbuzz-$name" $CMAKE_COMMON $CMAKE_CROSS_ARGS "$@"
  cmake --build "$WORKDIR/build-harfbuzz-$name" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-harfbuzz-$name"
  purge_shared_libs
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

if ! stamp_done "zlib-$ZLIB_VERSION"; then
  fetch zlib "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" \
        "zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION"
  run_cmake zlib "$SRCDIR/zlib-$ZLIB_VERSION" \
    -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_MINIZIP=OFF
  stamp_mark "zlib-$ZLIB_VERSION"
fi

# Targeting MinGW, zlib's CMake build installs libzs.a, but zlib.pc advertises
# -lz, which is what libpng, FreeType and HarfBuzz link.
if [ ! -f "$PREFIX/lib/libz.a" ]; then
  for zlib_candidate in libzs.a libzlibstatic.a; do
    if [ -f "$PREFIX/lib/$zlib_candidate" ]; then
      cp "$PREFIX/lib/$zlib_candidate" "$PREFIX/lib/libz.a"
      break
    fi
  done
fi
[ -f "$PREFIX/lib/libz.a" ] || { echo "no static zlib in $PREFIX/lib" >&2; exit 1; }

# FreeType reads WOFF2 files with brotli.
if ! stamp_done "brotli-$BROTLI_VERSION"; then
  fetch brotli "https://github.com/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz" \
        "brotli-$BROTLI_VERSION.tar.gz" "brotli-$BROTLI_VERSION"
  run_cmake brotli "$SRCDIR/brotli-$BROTLI_VERSION" -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUILD_TOOLS=OFF
  stamp_mark "brotli-$BROTLI_VERSION"
fi

# libpng is what FreeType loads the PNG glyphs of the sbix and CBDT tables
# with, and what hb-raster writes PNG files with.
if ! stamp_done "libpng-$LIBPNG_VERSION"; then
  fetch libpng "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG_VERSION.tar.gz" \
        "libpng-$LIBPNG_VERSION.tar.gz" "libpng-$LIBPNG_VERSION"
  run_cmake libpng "$SRCDIR/libpng-$LIBPNG_VERSION" \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
  stamp_mark "libpng-$LIBPNG_VERSION"
fi

# ---------------------------------------------------------------------------
# HarfBuzz
# ---------------------------------------------------------------------------

HB_SOURCE="$SRCDIR/harfbuzz-$HARFBUZZ_VERSION"
fetch harfbuzz "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz" \
      "harfbuzz-$HARFBUZZ_VERSION.tar.xz" "harfbuzz-$HARFBUZZ_VERSION"

# --force-fallback-for: GLib, its dependencies and FreeType are always the
# subprojects, whatever the build machine has installed. zlib, brotli and
# libpng are found in the prefix with pkg-config.
#
# auto_features=disabled: nothing is picked up because the build machine has
# it; what the tools are built with is enabled below.
#
# gobject: hb-info has --list-style, --list-metrics and --list-baselines only
# when HarfBuzz is built with it.
HB_BUILD="$WORKDIR/build-harfbuzz-harfbuzz"

if [ -n "$MINGW_TRIPLE" ]; then
  # glib-mkenums: HarfBuzz generates its GObject enumerations with the script of
  # the GLib subproject. Cross-compiling, meson 1.12 and later look for the
  # glib-mkenums of the build machine instead, and do not find the one of the
  # subproject, which is declared for Windows: they build GLib a second time,
  # for the build machine, in the directories of the first one. An entry in the
  # cross file comes before that lookup; the script is written while GLib is
  # configured, which is before HarfBuzz asks for it.
  glib_directory="$(sed -n 's/^directory *= *//p' "$HB_SOURCE/subprojects/glib.wrap")"
  [ -n "$glib_directory" ] || { echo "no directory in $HB_SOURCE/subprojects/glib.wrap" >&2; exit 1; }
  # -static links libc++, libunwind and winpthreads statically.
  cat > "$WORKDIR/harfbuzz-cross.txt" <<EOF
[binaries]
c = '$MINGW_TRIPLE-clang'
cpp = '$MINGW_TRIPLE-clang++'
ar = '$MINGW_TRIPLE-ar'
strip = '$MINGW_TRIPLE-strip'
windres = '$MINGW_TRIPLE-windres'
pkg-config = ['pkg-config', '--static']
glib-mkenums = ['python3', '$HB_BUILD/subprojects/$glib_directory/gobject/glib-mkenums']

[built-in options]
c_link_args = ['-static']
cpp_link_args = ['-static']

[properties]
pkg_config_libdir = '$PREFIX/lib/pkgconfig'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
  MESON_TARGET_ARGS="--cross-file $WORKDIR/harfbuzz-cross.txt"
fi

msg "configuring harfbuzz $HARFBUZZ_VERSION for $TARGET"
rm -rf "$HB_BUILD"
# shellcheck disable=SC2086
meson setup "$HB_BUILD" "$HB_SOURCE" $MESON_TARGET_ARGS \
  --buildtype=release -Ddefault_library=static -Dauto_features=disabled \
  --wrap-mode=default --force-fallback-for=glib,libffi,pcre2,proxy-libintl,freetype2 \
  -Dglib=enabled -Dgobject=enabled -Dfreetype=enabled -Dzlib=enabled -Dpng=enabled \
  -Dutilities=enabled -Dsubset=enabled -Dvector=enabled -Draster=enabled \
  -Dgpu=disabled -Dgpu_demo=disabled -Dcairo=disabled -Dchafa=disabled -Dicu=disabled \
  -Dgraphite2=disabled -Dcoretext=disabled -Ddirectwrite=disabled -Dgdi=disabled \
  -Dtests=disabled -Ddocs=disabled -Dintrospection=disabled -Dbenchmark=disabled \
  -Dfreetype2:zlib=system -Dfreetype2:brotli=enabled -Dfreetype2:png=enabled \
  -Dfreetype2:bzip2=disabled -Dfreetype2:harfbuzz=disabled \
  -Dglib:tests=false -Dglib:nls=disabled -Dglib:glib_debug=disabled -Dglib:xattr=false \
  -Dlibffi:tests=false

msg "building $TOOLS"
# shellcheck disable=SC2086
meson compile -C "$HB_BUILD" -j "$JOBS" $TOOLS

OUTPUTS=""
for tool in $TOOLS; do
  out="$WORKDIR/$tool-$TARGET$EXE"
  cp "$HB_BUILD/util/$tool$EXE" "$out"
  OUTPUTS="$OUTPUTS $out"
done

msg "stripping"
# shellcheck disable=SC2086
$STRIP $OUTPUTS
# shellcheck disable=SC2086
chmod +x $OUTPUTS

# shellcheck disable=SC2086
ls -lh $OUTPUTS
msg "built $TOOLS for $TARGET"
