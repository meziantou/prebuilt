#!/usr/bin/env bash
#
# Builds statically linked cjxl/djxl/jxlinfo/jxl_from_tree from the libjxl sources.
#
#   bash scripts/build-libjxl.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# Every target is built from source: the libjxl release has no macOS and no
# Linux arm64 binaries, and none of its archives contains jxl_from_tree, which
# is a developer tool (JPEGXL_ENABLE_DEVTOOLS).
#
# libjxl, highway, brotli and zlib are the versions ffmpeg is built with (see
# scripts/build-ffmpeg.sh), configured the same way, so that djxl decodes with
# the libjxl the published ffmpeg embeds. This script has its own prefix and
# does not share the one of build-ffmpeg.sh: that script is the key of the
# ffmpeg-deps cache, and it builds libjxl without the tools.
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
for name in ZLIB_VERSION LIBPNG_VERSION BROTLI_VERSION HWY_VERSION JXL_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
PREFIX="$WORKDIR/libjxl-deps"
SRCDIR="$WORKDIR/libjxl-src"
STAMPDIR="$PREFIX/.stamps"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS="cjxl djxl jxlinfo jxl_from_tree"

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
      tar -tzf "$out" >/dev/null 2>&1 && return 0
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
STRIP="strip"

case "$TARGET" in
  linux-*)
    # Same compiler as the ffmpeg build.
    export CC=clang CXX=clang++
    # musl's default thread stack is 128 KB, too small for the libjxl worker
    # threads; ffmpeg is linked with the same stack size.
    EXE_LDFLAGS="-static -Wl,-z,stack-size=2097152"
    ;;
  win-x64)
    EXE=".exe"
    [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
    export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
    MINGW_TRIPLE="x86_64-w64-mingw32"
    export MINGW_TRIPLE
    CMAKE_CROSS_ARGS="-DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/mingw-toolchain.cmake -DMINGW_TRIPLE=$MINGW_TRIPLE"
    # Links libc++, libunwind and winpthreads statically.
    EXE_LDFLAGS="-static"
    STRIP="$MINGW_TRIPLE-strip"
    ;;
  osx-arm64)
    # macOS has no static libSystem: the goal here is "no non-system dylibs".
    EXE_LDFLAGS=""
    STRIP="strip -x"
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    ;;
esac

# pkg-config must see the prefix and nothing else, so that Homebrew cannot leak
# a .dylib into the link.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

CMAKE_COMMON="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=OFF"

# run_cmake <name> <source dir> [extra cmake args...]
run_cmake() {
  name="$1"; src="$2"; shift 2
  msg "building $name"
  # shellcheck disable=SC2086
  cmake -S "$src" -B "$WORKDIR/build-libjxl-$name" $CMAKE_COMMON $CMAKE_CROSS_ARGS "$@"
  cmake --build "$WORKDIR/build-libjxl-$name" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-libjxl-$name"
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

# Targeting MinGW, zlib's CMake build installs libzs.a, a name the FindZLIB
# module of older CMake versions does not look for.
if [ ! -f "$PREFIX/lib/libz.a" ]; then
  for zlib_candidate in libzs.a libzlibstatic.a; do
    if [ -f "$PREFIX/lib/$zlib_candidate" ]; then
      cp "$PREFIX/lib/$zlib_candidate" "$PREFIX/lib/libz.a"
      break
    fi
  done
fi
[ -f "$PREFIX/lib/libz.a" ] || { echo "no static zlib in $PREFIX/lib" >&2; exit 1; }

# libpng is what cjxl and djxl read and write PNG and APNG with.
if ! stamp_done "libpng-$LIBPNG_VERSION"; then
  fetch libpng "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG_VERSION.tar.gz" \
        "libpng-$LIBPNG_VERSION.tar.gz" "libpng-$LIBPNG_VERSION"
  run_cmake libpng "$SRCDIR/libpng-$LIBPNG_VERSION" \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
  stamp_mark "libpng-$LIBPNG_VERSION"
fi

# brotli is only fetched: it is compiled as a part of libjxl, see below.
fetch brotli "https://github.com/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz" \
      "brotli-$BROTLI_VERSION.tar.gz" "brotli-$BROTLI_VERSION"

# highway tags carry no leading "v".
if ! stamp_done "highway-$HWY_VERSION"; then
  fetch highway "https://github.com/google/highway/archive/refs/tags/$HWY_VERSION.tar.gz" \
        "highway-$HWY_VERSION.tar.gz" "highway-$HWY_VERSION"
  run_cmake highway "$SRCDIR/highway-$HWY_VERSION" \
    -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=ON -DBUILD_TESTING=OFF
  stamp_mark "highway-$HWY_VERSION"
fi

# ---------------------------------------------------------------------------
# libjxl
# ---------------------------------------------------------------------------

JXL_SOURCE="$SRCDIR/libjxl-$JXL_VERSION"
fetch libjxl "https://github.com/libjxl/libjxl/archive/refs/tags/v$JXL_VERSION.tar.gz" \
      "libjxl-$JXL_VERSION.tar.gz" "libjxl-$JXL_VERSION"

# skcms is the only bundled dependency this build uses, so it is fetched alone,
# at the revision deps.sh pins: deps.sh also downloads the test images and
# seven libraries that are either provided above or turned off below.
if [ ! -f "$JXL_SOURCE/third_party/skcms/skcms.h" ]; then
  skcms_revision="$(sed -n 's/^THIRD_PARTY_SKCMS="\([0-9a-f]*\)".*/\1/p' "$JXL_SOURCE/deps.sh")"
  [ -n "$skcms_revision" ] || { echo "no skcms revision in $JXL_SOURCE/deps.sh" >&2; exit 1; }
  msg "fetching skcms $skcms_revision"
  download "https://github.com/google/skcms/archive/$skcms_revision.tar.gz" "$SRCDIR/skcms-$skcms_revision.tar.gz"
  rm -rf "$JXL_SOURCE/third_party/skcms"
  mkdir -p "$JXL_SOURCE/third_party/skcms"
  tar -xzf "$SRCDIR/skcms-$skcms_revision.tar.gz" -C "$JXL_SOURCE/third_party/skcms" --strip-components=1
fi

# brotli is built from third_party/brotli, as a subdirectory of libjxl, rather
# than installed in the prefix first: the module libjxl finds an installed
# brotli with declares its three libraries without their dependencies, and the
# tools then link libbrotlienc.a after libbrotlicommon.a, which GNU ld rejects.
rm -rf "$JXL_SOURCE/third_party/brotli"
ln -s "$SRCDIR/brotli-$BROTLI_VERSION" "$JXL_SOURCE/third_party/brotli"

# GIF, JPEG and OpenEXR are looked up unconditionally and would be linked
# dynamically where the build machine has them (Homebrew on macOS), so they are
# turned off. The lossless JPEG transcoding of cjxl and the JPEG reconstruction
# of djxl are part of libjxl itself and do not need libjpeg; without it, cjxl
# does not decode a JPEG to pixels and djxl does not encode pixels to JPEG.
#
# JPEGXL_STATIC is not used: it adds -static-libstdc++, which is wrong for the
# libc++ of llvm-mingw, so the linker flags are set from here.
JXL_BUILD="$WORKDIR/build-libjxl-libjxl"
msg "configuring libjxl $JXL_VERSION for $TARGET"
# shellcheck disable=SC2086
cmake -S "$JXL_SOURCE" -B "$JXL_BUILD" $CMAKE_COMMON $CMAKE_CROSS_ARGS \
  -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TOOLS=ON -DJPEGXL_ENABLE_DEVTOOLS=ON \
  -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
  -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF \
  -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_FUZZERS=OFF \
  -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_GIF=ON -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON \
  -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_VERSION="$JXL_VERSION" \
  -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_FORCE_SYSTEM_HWY=ON \
  -DCMAKE_EXE_LINKER_FLAGS="$EXE_LDFLAGS"

msg "building $TOOLS"
# shellcheck disable=SC2086
cmake --build "$JXL_BUILD" --parallel "$JOBS" --target $TOOLS

OUTPUTS=""
for tool in $TOOLS; do
  out="$WORKDIR/$tool-$TARGET$EXE"
  cp "$JXL_BUILD/tools/$tool$EXE" "$out"
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
