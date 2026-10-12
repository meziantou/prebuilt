#!/usr/bin/env bash
#
# Builds statically linked opj_compress/opj_decompress/opj_dump, the JPEG 2000
# tools of OpenJPEG.
#
#   bash scripts/build-openjpeg.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# Every target is built from the sources of the release tag: the OpenJPEG
# release has no Linux arm64 binaries.
#
# The tools are built without libpng, libtiff and LittleCMS, on purpose. They
# read and write PNM, PAM, PGX, raw, BMP and TGA files only, and opj_decompress
# cannot apply an ICC profile. The tools have no dependency then.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# OPENJPEG_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
[ -n "$OPENJPEG_VERSION" ] || { echo "OPENJPEG_VERSION is not set" >&2; exit 2; }

WORKDIR="$(pwd)"
SRCDIR="$WORKDIR/openjpeg-src"
SOURCE="$SRCDIR/openjpeg-$OPENJPEG_VERSION"
BUILD="$WORKDIR/build-openjpeg"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS="opj_compress opj_decompress opj_dump"

mkdir -p "$SRCDIR"

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
    EXE_LDFLAGS="-static"
    ;;
  win-x64)
    EXE=".exe"
    [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
    export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
    MINGW_TRIPLE="x86_64-w64-mingw32"
    export MINGW_TRIPLE
    CMAKE_CROSS_ARGS="-DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/mingw-toolchain.cmake -DMINGW_TRIPLE=$MINGW_TRIPLE"
    # Links winpthreads statically.
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

# ---------------------------------------------------------------------------
# OpenJPEG
# ---------------------------------------------------------------------------

if [ ! -d "$SOURCE" ]; then
  msg "fetching OpenJPEG $OPENJPEG_VERSION"
  download "https://github.com/uclouvain/openjpeg/archive/refs/tags/v$OPENJPEG_VERSION.tar.gz" \
           "$SRCDIR/openjpeg-$OPENJPEG_VERSION.tar.gz"
  ( cd "$SRCDIR" && tar -xzf "openjpeg-$OPENJPEG_VERSION.tar.gz" )
fi
[ -f "$SOURCE/CMakeLists.txt" ] || { echo "expected source directory $SOURCE not found" >&2; exit 1; }

# The image libraries are looked up on the build machine, and the tools are
# linked with whatever is found. BUILD_THIRDPARTY=OFF leaves the copies of the
# sources out, and the lookups are turned off: zlib is only there for libpng,
# and LCMS, LittleCMS 1, is what is looked up when LittleCMS 2 is missing.
#
# -fsigned-char: the tools read the signed 8-bit samples of raw and PGX files
# into a char, which is unsigned on Linux arm64. Without it, opj_compress reads
# the negative samples as 128 to 255 there, and clips them to 127.
msg "configuring OpenJPEG $OPENJPEG_VERSION for $TARGET"
# shellcheck disable=SC2086
cmake -S "$SOURCE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS_ARGS \
  -DCMAKE_C_FLAGS=-fsigned-char \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
  -DBUILD_CODEC=ON -DBUILD_THIRDPARTY=OFF -DBUILD_JPIP=OFF -DBUILD_TESTING=OFF -DBUILD_DOC=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_LCMS2=ON -DCMAKE_DISABLE_FIND_PACKAGE_LCMS=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_ZLIB=ON \
  "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"

# What the configuration found is written to this header.
apps_config="$BUILD/src/bin/common/opj_apps_config.h"
[ -f "$apps_config" ] || { echo "$apps_config was not generated" >&2; exit 1; }
if grep -E '^[[:space:]]*#[[:space:]]*define[[:space:]]+OPJ_HAVE_LIB' "$apps_config"; then
  echo "the tools are configured with an image library" >&2; exit 1
fi

msg "building $TOOLS"
# shellcheck disable=SC2086
cmake --build "$BUILD" --parallel "$JOBS" --target $TOOLS

OUTPUTS=""
for tool in $TOOLS; do
  [ -f "$BUILD/bin/$tool$EXE" ] || { echo "$tool$EXE was not built in $BUILD/bin" >&2; exit 1; }
  out="$WORKDIR/$tool-$TARGET$EXE"
  cp "$BUILD/bin/$tool$EXE" "$out"
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
