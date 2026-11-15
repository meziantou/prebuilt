#!/usr/bin/env bash
#
# Builds a statically linked astcenc, the ASTC encoder and decoder of Arm
# (https://github.com/ARM-software/astc-encoder), from the release tag:
#
#   astcenc-<target>[.exe]
#
#   bash scripts/build-astcenc.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# astcenc is built for no SIMD instruction set (ASTCENC_ISA_NONE, the
# reference C++ code; the executable is astcenc-none), so that every target
# runs the same code and writes the same bytes; the release builds it with the
# invariance option, which is the default. It has no dependency: it reads and
# writes PNG, TGA, BMP, JPEG, HDR (stb_image), EXR (tinyexr), KTX and DDS by
# itself.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# ASTCENC_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

TOOL_ID=astcenc
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"

require_versions ASTCENC_VERSION

fetch astcenc "https://github.com/ARM-software/astc-encoder/archive/refs/tags/$ASTCENC_VERSION.tar.gz" \
      "astc-encoder-$ASTCENC_VERSION.tar.gz" "astc-encoder-$ASTCENC_VERSION"
SOURCE="$SRCDIR/astc-encoder-$ASTCENC_VERSION"

# The MinGW headers are lowercase, and the Linux machine that cross-compiles
# win-x64 has a case-sensitive file system.
sed 's/<Processthreadsapi.h>/<processthreadsapi.h>/' "$SOURCE/Source/astcenccli_platform_dependents.cpp" \
  > "$SOURCE/Source/astcenccli_platform_dependents.cpp.tmp"
mv "$SOURCE/Source/astcenccli_platform_dependents.cpp.tmp" "$SOURCE/Source/astcenccli_platform_dependents.cpp"
grep -q 'Processthreadsapi' "$SOURCE/Source/astcenccli_platform_dependents.cpp" && { echo "the include of Processthreadsapi.h is not patched" >&2; exit 1; }

# astcenc archives its objects with CMAKE_CXX_COMPILER_AR, which CMake sets for
# clang from llvm-ar only: Alpine has no llvm-ar, the binutils ar does.
AR_ARGS=""
case "$TARGET" in
  linux-*) AR_ARGS="-DCMAKE_CXX_COMPILER_AR=$(command -v ar) -DCMAKE_CXX_COMPILER_RANLIB=$(command -v ranlib)" ;;
esac

BUILD="$WORKDIR/build-astcenc"
msg "configuring astcenc $ASTCENC_VERSION for $TARGET"
rm -rf "$BUILD"
# shellcheck disable=SC2086
cmake -S "$SOURCE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS_ARGS $AR_ARGS \
  -DASTCENC_ISA_NONE=ON -DASTCENC_ISA_NEON=OFF -DASTCENC_ISA_SVE_128=OFF -DASTCENC_ISA_SVE_256=OFF \
  -DASTCENC_ISA_SSE2=OFF -DASTCENC_ISA_SSE41=OFF -DASTCENC_ISA_AVX2=OFF -DASTCENC_ISA_NATIVE=OFF \
  -DASTCENC_UNIVERSAL_BUILD=OFF -DASTCENC_CLI=ON -DASTCENC_SHAREDLIB=OFF -DASTCENC_UNITTEST=OFF \
  -DASTCENC_DECOMPRESSOR=OFF -DASTCENC_DIAGNOSTICS=OFF -DASTCENC_ASAN=OFF \
  "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"

msg "building astcenc-none"
cmake --build "$BUILD" --parallel "$JOBS" --target astcenc-none

built="$(find "$BUILD" -type f -name "astcenc-none$EXE" | sed -n 1p)"
[ -n "$built" ] || { echo "astcenc-none$EXE was not built in $BUILD" >&2; exit 1; }
out="$WORKDIR/astcenc-$TARGET$EXE"
cp "$built" "$out"
finish_outputs "$out"
msg "built astcenc for $TARGET"
