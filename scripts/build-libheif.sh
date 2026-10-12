#!/usr/bin/env bash
#
# Builds statically linked dec265 (libde265) and heif-enc/heif-dec/heif-info
# (libheif) from their sources.
#
#   bash scripts/build-libheif.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# libheif is built for HEVC only, with one encoder and one decoder, so that
# what heif-enc and heif-dec use is not ambiguous:
# - x265 encodes. It is the x265 ffmpeg is built with, for 8, 10 and 12 bits
#   (see scripts/x265-multilib.sh);
# - libde265 decodes. dec265 and heif-dec are linked with the same libde265.a.
# The plugin loading and every other codec are turned off: AV1, JPEG, JPEG 2000,
# HT-J2K, VVC, AVC, the uncompressed codec and the ffmpeg HEVC decoder.
# libpng reads and writes the PNG files, including the 16-bit ones.
#
# dec265 is built without SDL and without videogfx, which it only uses to
# display the pictures.
#
# zlib and libpng are the versions the libjxl and HarfBuzz tools are built
# with. This script has its own prefix, as scripts/build-libjxl.sh does.
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
for name in ZLIB_VERSION LIBPNG_VERSION X265_VERSION LIBDE265_VERSION LIBHEIF_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
PREFIX="$WORKDIR/libheif-deps"
SRCDIR="$WORKDIR/libheif-src"
STAMPDIR="$PREFIX/.stamps"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEIF_TOOLS="heif-enc heif-dec heif-info"

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
    # musl's default thread stack is 128 KB, too small for the x265 worker
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

# build_x265_multilib
. "$SCRIPT_DIR/x265-multilib.sh"

CMAKE_COMMON="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=OFF"

# run_cmake <name> <source dir> [extra cmake args...]
run_cmake() {
  name="$1"; src="$2"; shift 2
  msg "building $name"
  # shellcheck disable=SC2086
  cmake -S "$src" -B "$WORKDIR/build-libheif-$name" $CMAKE_COMMON $CMAKE_CROSS_ARGS "$@"
  cmake --build "$WORKDIR/build-libheif-$name" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-libheif-$name"
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

# libpng is what heif-enc and heif-dec read and write PNG with.
if ! stamp_done "libpng-$LIBPNG_VERSION"; then
  fetch libpng "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG_VERSION.tar.gz" \
        "libpng-$LIBPNG_VERSION.tar.gz" "libpng-$LIBPNG_VERSION"
  run_cmake libpng "$SRCDIR/libpng-$LIBPNG_VERSION" \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
  stamp_mark "libpng-$LIBPNG_VERSION"
fi

# The x265 tool is not built here: scripts/build-ffmpeg.sh publishes it.
if ! stamp_done "x265-$X265_VERSION-multilib"; then
  build_x265_multilib build-libheif-x265 OFF ""
  stamp_mark "x265-$X265_VERSION-multilib"
fi

# ---------------------------------------------------------------------------
# libde265 and dec265
# ---------------------------------------------------------------------------

# SDL is only looked up when ENABLE_SDL is set; it is disabled twice so that
# the SDL of the build machine (Homebrew on macOS) cannot be linked. libde265
# has no option for videogfx: its CMake build never defines HAVE_VIDEOGFX.
# The encoder of libde265 is not built: upstream calls it defunct.
if ! stamp_done "libde265-$LIBDE265_VERSION"; then
  fetch libde265 "https://github.com/strukturag/libde265/archive/refs/tags/v$LIBDE265_VERSION.tar.gz" \
        "libde265-$LIBDE265_VERSION.tar.gz" "libde265-$LIBDE265_VERSION"
  run_cmake libde265 "$SRCDIR/libde265-$LIBDE265_VERSION" \
    -DENABLE_DECODER=ON -DENABLE_ENCODER=OFF -DENABLE_SDL=OFF -DCMAKE_DISABLE_FIND_PACKAGE_SDL2=ON \
    -DENABLE_SHERLOCK265=OFF -DENABLE_INTERNAL_DEVELOPMENT_TOOLS=OFF -DWITH_FUZZERS=OFF \
    "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"
  stamp_mark "libde265-$LIBDE265_VERSION"
fi
[ -f "$PREFIX/bin/dec265$EXE" ] || { echo "dec265$EXE was not installed in $PREFIX/bin" >&2; exit 1; }

# ---------------------------------------------------------------------------
# libheif
# ---------------------------------------------------------------------------

HEIF_SOURCE="$SRCDIR/libheif-$LIBHEIF_VERSION"
fetch libheif "https://github.com/strukturag/libheif/archive/refs/tags/v$LIBHEIF_VERSION.tar.gz" \
      "libheif-$LIBHEIF_VERSION.tar.gz" "libheif-$LIBHEIF_VERSION"

# Every codec has a WITH_<codec> option, and most of them are looked up on the
# build machine when it is ON or left to its default, so each one is set.
# JPEG, TIFF and WebP are not options: the tools use the libraries when CMake
# finds them, hence CMAKE_DISABLE_FIND_PACKAGE_<name>. PNG is required instead,
# so that a build without PNG support fails here.
#
# Linked statically, libde265 and libheif need LIBDE265_STATIC_BUILD and
# LIBHEIF_STATIC_BUILD not to declare their functions as imported from a DLL
# on Windows; libheif defines neither for its own targets.
#
# The image sequences and the grid images need no option. The "tili" and
# "unci" tiling methods of heif-enc are not built: they belong to the
# experimental features and to the uncompressed codec.
HEIF_BUILD="$WORKDIR/build-libheif-libheif"
HEIF_DEFINES="-DLIBDE265_STATIC_BUILD -DLIBHEIF_STATIC_BUILD"
msg "configuring libheif $LIBHEIF_VERSION for $TARGET"
# shellcheck disable=SC2086
cmake -S "$HEIF_SOURCE" -B "$HEIF_BUILD" $CMAKE_COMMON $CMAKE_CROSS_ARGS \
  -DENABLE_PLUGIN_LOADING=OFF \
  -DWITH_LIBDE265=ON -DWITH_LIBDE265_PLUGIN=OFF -DWITH_X265=ON -DWITH_X265_PLUGIN=OFF \
  -DWITH_KVAZAAR=OFF -DWITH_FFMPEG_DECODER=OFF \
  -DWITH_X264=OFF -DWITH_OpenH264_DECODER=OFF \
  -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF -DWITH_DAV1D=OFF -DWITH_SvtEnc=OFF -DWITH_RAV1E=OFF \
  -DWITH_UVG266=OFF -DWITH_VVDEC=OFF -DWITH_VVENC=OFF \
  -DWITH_JPEG_DECODER=OFF -DWITH_JPEG_ENCODER=OFF \
  -DWITH_OpenJPEG_DECODER=OFF -DWITH_OpenJPEG_ENCODER=OFF -DWITH_OPENJPH_ENCODER=OFF \
  -DWITH_UNCOMPRESSED_CODEC=OFF -DWITH_WEBCODECS=OFF \
  -DWITH_LIBSHARPYUV=OFF -DWITH_HEADER_COMPRESSION=OFF -DENABLE_EXPERIMENTAL_FEATURES=OFF \
  -DWITH_EXAMPLES=ON -DWITH_EXAMPLE_HEIF_VIEW=OFF -DWITH_EXAMPLE_HEIF_THUMB=OFF -DWITH_GDK_PIXBUF=OFF \
  -DBUILD_TESTING=OFF -DBUILD_DOCUMENTATION=OFF -DBUILD_DEVELOPMENT_TOOLS=OFF -DWITH_FUZZERS=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_WEBP=ON -DCMAKE_REQUIRE_FIND_PACKAGE_PNG=ON \
  "-DCMAKE_C_FLAGS=$HEIF_DEFINES" "-DCMAKE_CXX_FLAGS=$HEIF_DEFINES" \
  "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"

msg "building $HEIF_TOOLS"
# shellcheck disable=SC2086
cmake --build "$HEIF_BUILD" --parallel "$JOBS" --target $HEIF_TOOLS

OUTPUTS="$WORKDIR/dec265-$TARGET$EXE"
cp "$PREFIX/bin/dec265$EXE" "$WORKDIR/dec265-$TARGET$EXE"
for tool in $HEIF_TOOLS; do
  out="$WORKDIR/$tool-$TARGET$EXE"
  cp "$HEIF_BUILD/examples/$tool$EXE" "$out"
  OUTPUTS="$OUTPUTS $out"
done

msg "stripping"
# shellcheck disable=SC2086
$STRIP $OUTPUTS
# shellcheck disable=SC2086
chmod +x $OUTPUTS

# shellcheck disable=SC2086
ls -lh $OUTPUTS
msg "built dec265 $HEIF_TOOLS for $TARGET"
