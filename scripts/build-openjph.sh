#!/usr/bin/env bash
#
# Builds statically linked ojph_compress/ojph_expand, the HTJ2K (JPEG 2000
# Part 15, High Throughput) tools of OpenJPH.
#
#   bash scripts/build-openjph.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# OpenJPH publishes no binaries, so every target is built from the sources of
# the release tag. It has no dependency: TIFF support, which needs libtiff, is
# left out, so the tools read and write PGM, PPM, PFM, yuv and raw files.
#
# The SIMD code is kept: OpenJPH compiles it in separate files and picks one at
# run time from what the processor supports.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# OPENJPH_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
[ -n "$OPENJPH_VERSION" ] || { echo "OPENJPH_VERSION is not set" >&2; exit 2; }

WORKDIR="$(pwd)"
SRCDIR="$WORKDIR/openjph-src"
SOURCE="$SRCDIR/OpenJPH-$OPENJPH_VERSION"
BUILD="$WORKDIR/build-openjph"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS="ojph_compress ojph_expand"

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

# ---------------------------------------------------------------------------
# OpenJPH
# ---------------------------------------------------------------------------

# The tags have no leading v.
if [ ! -d "$SOURCE" ]; then
  msg "fetching OpenJPH $OPENJPH_VERSION"
  download "https://github.com/aous72/OpenJPH/archive/refs/tags/$OPENJPH_VERSION.tar.gz" \
           "$SRCDIR/OpenJPH-$OPENJPH_VERSION.tar.gz"
  ( cd "$SRCDIR" && tar -xzf "OpenJPH-$OPENJPH_VERSION.tar.gz" )
fi
[ -f "$SOURCE/CMakeLists.txt" ] || { echo "expected source directory $SOURCE not found" >&2; exit 1; }

# The library is shared by default, and TIFF support is on by default: libtiff
# is then looked up on the build machine.
msg "configuring OpenJPH $OPENJPH_VERSION for $TARGET"
# shellcheck disable=SC2086
cmake -S "$SOURCE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS_ARGS \
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
  -DOJPH_BUILD_EXECUTABLES=ON -DOJPH_BUILD_STREAM_EXPAND=OFF -DOJPH_ENABLE_TIFF_SUPPORT=OFF \
  -DOJPH_BUILD_TESTS=OFF -DOJPH_BUILD_FUZZER=OFF \
  "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"

msg "building $TOOLS"
# shellcheck disable=SC2086
cmake --build "$BUILD" --parallel "$JOBS" --target $TOOLS

OUTPUTS=""
for tool in $TOOLS; do
  built="$(find "$BUILD" -type f -name "$tool$EXE" | sed -n 1p)"
  [ -n "$built" ] || { echo "$tool$EXE was not built in $BUILD" >&2; exit 1; }
  out="$WORKDIR/$tool-$TARGET$EXE"
  cp "$built" "$out"
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
