#!/usr/bin/env bash
#
# Builds a statically linked basisu, the Basis Universal encoder, transcoder
# and validator (https://github.com/BinomialLLC/basis_universal), from the
# release tag:
#
#   basisu-<target>[.exe]
#
#   bash scripts/build-basisu.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# basisu writes .basis and KTX2 files with ETC1S, UASTC LDR 4x4 and the HDR
# formats (UASTC HDR 4x4, ASTC HDR 6x6), with Zstandard supercompression (its
# copy of zstd), and unpacks them to every GPU format it transcodes to. It is
# built without SSE 4.1 (BASISU_SSE, which only some x64 machines have) and
# without OpenCL, so that every target runs the same code.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# BASISU_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

TOOL_ID=basisu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"

require_versions BASISU_VERSION

# The tags are v<major>_<minor>: v2_50 for 2.50.
TAG="v$(echo "$BASISU_VERSION" | tr . _)"
fetch basisu "https://github.com/BinomialLLC/basis_universal/archive/refs/tags/$TAG.tar.gz" \
      "basis_universal-$BASISU_VERSION.tar.gz" "basis_universal-${TAG#v}"
SOURCE="$SRCDIR/basis_universal-${TAG#v}"

BUILD="$WORKDIR/build-basisu"
msg "configuring basisu $BASISU_VERSION for $TARGET"
rm -rf "$BUILD" "$SOURCE/bin"
# BASISU_STATIC is not used: it links with -static on macOS too. The tool is
# written to $SOURCE/bin (CMAKE_RUNTIME_OUTPUT_DIRECTORY).
# shellcheck disable=SC2086
cmake -S "$SOURCE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS_ARGS \
  -DBASISU_STATIC=FALSE -DBASISU_SSE=FALSE -DBASISU_OPENCL=FALSE -DBASISU_ZSTD=TRUE \
  -DBASISU_EXAMPLES=FALSE -DBASISU_BUILD_PYTHON=OFF -DBASISU_SAN=FALSE -DBASISU_SUPPORT_ASTCENC=FALSE \
  "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"

msg "building basisu"
cmake --build "$BUILD" --parallel "$JOBS" --target basisu

built="$(find "$SOURCE/bin" "$BUILD" -type f -name "basisu$EXE" | sed -n 1p)"
[ -n "$built" ] || { echo "basisu$EXE was not built" >&2; exit 1; }
out="$WORKDIR/basisu-$TARGET$EXE"
cp "$built" "$out"
finish_outputs "$out"
msg "built basisu for $TARGET"
