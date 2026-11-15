#!/usr/bin/env bash
#
# Builds statically linked dcraw_emu, raw-identify and unprocessed_raw, the
# sample programs of LibRaw (https://www.libraw.org), from the release tarball:
#
#   dcraw_emu-<target>[.exe], raw-identify-<target>[.exe],
#   unprocessed_raw-<target>[.exe]
#
#   bash scripts/build-libraw.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# LibRaw publishes Windows and macOS binaries of its samples only. It is built
# with zlib (deflate-compressed DNG), libjpeg-turbo (lossy DNG, built without
# its SIMD code) and LittleCMS 2 (output profiles), the versions the PDF tools
# are built with (scripts/pdf-libs.sh), and without OpenMP, so that every
# target decodes the same samples.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# LIBRAW_VERSION and the versions of the libraries come from the environment
# (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

TOOL_ID=libraw
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"
. "$SCRIPT_DIR/pdf-libs.sh"

require_versions LIBRAW_VERSION
TOOLS="dcraw_emu raw-identify unprocessed_raw"

build_zlib
build_libjpeg_turbo
build_lcms2

fetch LibRaw "https://www.libraw.org/data/LibRaw-$LIBRAW_VERSION.tar.gz" \
      "LibRaw-$LIBRAW_VERSION.tar.gz" "LibRaw-$LIBRAW_VERSION"
SOURCE="$SRCDIR/LibRaw-$LIBRAW_VERSION"

CONFIGURE_HOST=""
LIBTOOL_LDFLAGS=""
case "$TARGET" in
  linux-*) LIBTOOL_LDFLAGS="-all-static" ;;
  win-x64) CONFIGURE_HOST="--host=$MINGW_TRIPLE"; LIBTOOL_LDFLAGS="-all-static" ;;
esac

# Everything in the prefix is a static library, whose private dependencies are
# needed too.
export PKG_CONFIG="pkg-config --static"

BUILD="$WORKDIR/build-libraw"
msg "configuring LibRaw $LIBRAW_VERSION for $TARGET"
rm -rf "$BUILD"
mkdir -p "$BUILD"
# shellcheck disable=SC2086
( cd "$BUILD" \
  && CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
     "$SOURCE/configure" $CONFIGURE_HOST --prefix="$PREFIX" --disable-shared --enable-static \
       --disable-openmp --enable-jpeg --enable-zlib --enable-lcms --enable-examples --disable-dependency-tracking )
for feature in USE_JPEG USE_ZLIB USE_LCMS2; do
  grep -q -- "-D$feature" "$BUILD/Makefile" || { echo "LibRaw was configured without $feature" >&2; exit 1; }
done

msg "building $TOOLS"
targets=""
for tool in $TOOLS; do targets="$targets bin/$tool$EXE"; done
# shellcheck disable=SC2086
make -C "$BUILD" -j"$JOBS" LDFLAGS="-L$PREFIX/lib $LIBTOOL_LDFLAGS" $targets

OUTPUTS=""
for tool in $TOOLS; do
  out="$WORKDIR/$tool-$TARGET$EXE"
  cp "$BUILD/bin/$tool$EXE" "$out"
  OUTPUTS="$OUTPUTS $out"
done
# shellcheck disable=SC2086
finish_outputs $OUTPUTS
msg "built $TOOLS for $TARGET"
