#!/usr/bin/env bash
#
# Builds statically linked OpenEXR command-line tools: the utilities of the
# OpenEXR release (exrheader, exrinfo, exrmaketiled, exrmetrics, exrstdattr,
# exrcheck, exrmultipart, exrmultiview, exrenvmap, exrmakepreview, exrmanifest,
# exr2aces), and exr-from-raw and exr-to-raw, two programs of this repository
# (scripts/exr-from-raw.cpp, scripts/exr-to-raw.cpp) that write an EXR file
# from raw samples and a JSON description, and dump the header and the decoded
# samples of an EXR file. Their command line and formats are described at the
# top of their sources and in src/Meziantou.Prebuilt/README.md.
#
#   bash scripts/build-openexr.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# OpenEXR publishes no binaries, so every target is built from the sources of
# the release tag. The release tarball comes with the libdeflate, zstd and
# OpenJPH it is tested with (external/), which are always used, even when the
# build machine has its own: nothing is looked up on the build machine. Imath is
# the version OpenEXR pins (OPENEXR_IMATH_TAG of cmake/OpenEXRSetup.cmake),
# downloaded here instead of the git clone of FetchContent; the build fails when
# IMATH_VERSION is not that version.
#
# Everything is compiled with -ffp-contract=off: without it, clang fuses the
# multiplications and additions of the lossy codecs (DWAA, DWAB, B44, PXR24)
# into FMA instructions on arm64 and not on x64, and the decoded samples could
# depend on the processor. For the same reason, the SIMD code OpenEXR and
# OpenJPH select at run time on x64 is left out: OpenJPH is built with
# OJPH_DISABLE_SIMD (it has no arm64 SIMD code), and the DWA decoder keeps its
# scalar inverse DCT (see below). scripts/verify-openexr.sh checks the hash of
# the decoded samples of a fixed input on every target.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# OPENEXR_VERSION and IMATH_VERSION come from the environment (see
# .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
for name in OPENEXR_VERSION IMATH_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
SRCDIR="$WORKDIR/openexr-src"
SOURCE="$SRCDIR/openexr-$OPENEXR_VERSION"
IMATH_SOURCE="$SRCDIR/Imath-$IMATH_VERSION"
BUILD="$WORKDIR/build-openexr"
PREFIX="$BUILD/install"
RAW_TOOLS_BUILD="$WORKDIR/build-openexr-raw-tools"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_TOOLS="exrheader exrinfo exrmaketiled exrmetrics exrstdattr exrcheck exrmultipart exrmultiview exrenvmap exrmakepreview exrmanifest exr2aces"
RAW_TOOLS="exr-from-raw exr-to-raw"

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
# See the top of this file.
FP_FLAGS="-ffp-contract=off"

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
# Sources
# ---------------------------------------------------------------------------

if [ ! -d "$SOURCE" ]; then
  msg "fetching OpenEXR $OPENEXR_VERSION"
  download "https://github.com/AcademySoftwareFoundation/openexr/archive/refs/tags/v$OPENEXR_VERSION.tar.gz" \
           "$SRCDIR/openexr-$OPENEXR_VERSION.tar.gz"
  ( cd "$SRCDIR" && tar -xzf "openexr-$OPENEXR_VERSION.tar.gz" )
fi
[ -f "$SOURCE/CMakeLists.txt" ] || { echo "expected source directory $SOURCE not found" >&2; exit 1; }

# The Imath OpenEXR pins, which FetchContent would clone.
pinned_imath="$(sed -n 's/^set(OPENEXR_IMATH_TAG "v\([^"]*\)".*/\1/p' "$SOURCE/cmake/OpenEXRSetup.cmake")"
[ -n "$pinned_imath" ] || { echo "no OPENEXR_IMATH_TAG in $SOURCE/cmake/OpenEXRSetup.cmake" >&2; exit 1; }
[ "$pinned_imath" = "$IMATH_VERSION" ] \
  || { echo "OpenEXR $OPENEXR_VERSION pins Imath $pinned_imath, but IMATH_VERSION is $IMATH_VERSION" >&2; exit 1; }

if [ ! -d "$IMATH_SOURCE" ]; then
  msg "fetching Imath $IMATH_VERSION"
  download "https://github.com/AcademySoftwareFoundation/Imath/archive/refs/tags/v$IMATH_VERSION.tar.gz" \
           "$SRCDIR/Imath-$IMATH_VERSION.tar.gz"
  ( cd "$SRCDIR" && tar -xzf "Imath-$IMATH_VERSION.tar.gz" )
fi
[ -f "$IMATH_SOURCE/CMakeLists.txt" ] || { echo "expected source directory $IMATH_SOURCE not found" >&2; exit 1; }

for dependency in deflate zstd OpenJPH; do
  [ -d "$SOURCE/external/$dependency" ] || { echo "OpenEXR $OPENEXR_VERSION has no external/$dependency" >&2; exit 1; }
done

# On x64, the DWAA/DWAB decoder picks an AVX or SSE2 inverse DCT and an F16C
# half conversion at run time; arm64 always uses the scalar DCT. The SIMD DCTs
# round differently, so the decoded samples would depend on the processor (see
# the top of this file). Skipping the processor check keeps every x64 machine on
# the scalar code, like arm64. The check is the only line of OpenEXR this build
# changes; the build fails when a new release no longer has it.
DWA_SIMD="$SOURCE/src/lib/OpenEXRCore/internal_dwa_simd.h"
DWA_SIMD_CHECK='    check_for_x86_simd (&f16c, &avx, &sse2);'
DWA_SIMD_PATCHED='    /* meziantou/prebuilt: scalar DCT on every processor */'
if ! grep -qF "$DWA_SIMD_PATCHED" "$DWA_SIMD"; then
  [ "$(grep -cF "$DWA_SIMD_CHECK" "$DWA_SIMD")" = 1 ] \
    || { echo "$DWA_SIMD does not call check_for_x86_simd exactly once" >&2; exit 1; }
  awk -v check="$DWA_SIMD_CHECK" -v patched="$DWA_SIMD_PATCHED" \
    '$0 == check { print patched; next } { print }' "$DWA_SIMD" > "$DWA_SIMD.tmp"
  mv "$DWA_SIMD.tmp" "$DWA_SIMD"
fi

# ---------------------------------------------------------------------------
# OpenEXR
# ---------------------------------------------------------------------------

# The libraries are shared by default. The tests, the examples and the website
# are left out; exrcheck is a "developer tool" that is built but not installed.
msg "configuring OpenEXR $OPENEXR_VERSION for $TARGET"
# shellcheck disable=SC2086
cmake -S "$SOURCE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS_ARGS \
  "-DCMAKE_INSTALL_PREFIX=$PREFIX" \
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
  -DBUILD_TESTING=OFF -DOPENEXR_BUILD_EXAMPLES=OFF -DOPENEXR_BUILD_PYTHON=OFF -DOPENEXR_BUILD_DOCS=OFF \
  -DOPENEXR_BUILD_TOOLS=ON -DOPENEXR_INSTALL_TOOLS=ON -DOPENEXR_INSTALL_PKG_CONFIG=OFF \
  -DOPENEXR_FORCE_INTERNAL_DEFLATE=ON -DOPENEXR_FORCE_INTERNAL_ZSTD=ON -DOPENEXR_FORCE_INTERNAL_OPENJPH=ON \
  -DOPENEXR_FORCE_INTERNAL_IMATH=ON "-DFETCHCONTENT_SOURCE_DIR_IMATH=$IMATH_SOURCE" -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DOJPH_DISABLE_SIMD=ON \
  "-DCMAKE_C_FLAGS=$FP_FLAGS" "-DCMAKE_CXX_FLAGS=$FP_FLAGS" \
  "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"

msg "building OpenEXR"
cmake --build "$BUILD" --parallel "$JOBS"
cmake --install "$BUILD"

# ---------------------------------------------------------------------------
# exr-from-raw and exr-to-raw
# ---------------------------------------------------------------------------

# Built against the installed static libraries, with the same flags. The
# sources include exr-raw-common.h from their own folder.
[ -f "$SCRIPT_DIR/exr-raw-common.h" ] || { echo "missing $SCRIPT_DIR/exr-raw-common.h" >&2; exit 1; }
mkdir -p "$RAW_TOOLS_BUILD"
cat > "$RAW_TOOLS_BUILD/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.14)
project(exr_raw_tools CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
find_package(OpenEXR CONFIG REQUIRED)
add_executable(exr-from-raw "$SCRIPT_DIR/exr-from-raw.cpp")
add_executable(exr-to-raw "$SCRIPT_DIR/exr-to-raw.cpp")
foreach(tool exr-from-raw exr-to-raw)
  target_link_libraries(\${tool} PRIVATE OpenEXR::OpenEXR)
  target_compile_definitions(\${tool} PRIVATE "EXR_RAW_TOOLS_OPENEXR_VERSION=\"$OPENEXR_VERSION\"")
  if(NOT MSVC)
    target_compile_options(\${tool} PRIVATE -Wall -Wextra -Werror)
  endif()
endforeach()
EOF

msg "configuring $RAW_TOOLS"
# shellcheck disable=SC2086
cmake -S "$RAW_TOOLS_BUILD" -B "$RAW_TOOLS_BUILD/build" -G Ninja -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS_ARGS \
  "-DOpenEXR_DIR=$PREFIX/lib/cmake/OpenEXR" "-DImath_DIR=$PREFIX/lib/cmake/Imath" \
  "-DCMAKE_CXX_FLAGS=$FP_FLAGS" \
  "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"

msg "building $RAW_TOOLS"
cmake --build "$RAW_TOOLS_BUILD/build" --parallel "$JOBS"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

OUTPUTS=""
for tool in $RELEASE_TOOLS; do
  built="$BUILD/bin/$tool$EXE"
  [ -f "$built" ] || { echo "$tool$EXE was not built in $BUILD/bin" >&2; exit 1; }
  out="$WORKDIR/$tool-$TARGET$EXE"
  cp "$built" "$out"
  OUTPUTS="$OUTPUTS $out"
done
for tool in $RAW_TOOLS; do
  built="$RAW_TOOLS_BUILD/build/$tool$EXE"
  [ -f "$built" ] || { echo "$tool$EXE was not built in $RAW_TOOLS_BUILD/build" >&2; exit 1; }
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
msg "built $RELEASE_TOOLS $RAW_TOOLS for $TARGET"
