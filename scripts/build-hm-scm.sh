#!/usr/bin/env bash
#
# Builds statically linked TAppEncoderSCM/TAppDecoderSCM, the encoder and the
# decoder of HM-SCM, the HEVC reference software with the screen content coding
# extensions (SCC: palette mode, intra block copy, adaptive color transform,
# adaptive motion vector resolution), which HM itself does not have:
#
#   TAppEncoderSCM-<target>[.exe], TAppDecoderSCM-<target>[.exe]
#
#   bash scripts/build-hm-scm.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# HM-SCM is the last HM release with the SCC software, tagged
# HM-<HM version>+SCM-<SCM version> in the HM repository; HM publishes no
# binaries. It is built as scripts/build-hm.sh builds HM, with the same
# patches of its CMakeLists.txt and HIGH_BITDEPTH: every target runs the same
# C++ code. It has no dependency.
#
# The multilayer extensions (SHVC, MV-HEVC) are not in HM or HM-SCM: they are
# the SHM and HTM software, which are not built.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# HM_SCM_VERSION comes from the environment (see .github/workflows/ci.yml):
# "16.21+8.8" is the tag HM-16.21+SCM-8.8.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
[ -n "$HM_SCM_VERSION" ] || { echo "HM_SCM_VERSION is not set" >&2; exit 2; }
HM_TAG="HM-${HM_SCM_VERSION%%+*}+SCM-${HM_SCM_VERSION#*+}"

WORKDIR="$(pwd)"
SRCDIR="$WORKDIR/hm-scm-src"
SOURCE="$SRCDIR/HM-$HM_TAG"
BUILD="$WORKDIR/build-hm-scm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS="TAppEncoder TAppDecoder"

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
# HM
# ---------------------------------------------------------------------------

if [ ! -d "$SOURCE" ]; then
  msg "fetching $HM_TAG"
  url_tag="$(echo "$HM_TAG" | sed 's/+/%2B/g')"
  download "https://vcgit.hhi.fraunhofer.de/jvet/HM/-/archive/$url_tag/HM-$url_tag.tar.gz" \
           "$SRCDIR/$HM_TAG.tar.gz"
  ( cd "$SRCDIR" && tar -xzf "$HM_TAG.tar.gz" )
fi
[ -f "$SOURCE/CMakeLists.txt" ] || { echo "expected source directory $SOURCE not found" >&2; exit 1; }

# Two things in the CMakeLists.txt of the release do not build with a current
# clang, and neither has an option:
# - every warning is an error, and the compilers have gained warnings since;
# - -msse4.1 is passed on every Unix and MinGW target, which is an error
#   for arm64. Upstream guards it the same way after the release.
# Both are checked, so that a new HM version that changes these lines fails
# here rather than with a compiler error.
hm_cmake="$SOURCE/CMakeLists.txt"
if grep -q ' warnings-as-errors' "$hm_cmake" || grep -q '^if( UNIX OR MINGW )$' "$hm_cmake"; then
  msg "patching CMakeLists.txt"
  sed -e 's/ warnings-as-errors//' \
      -e 's/^if( UNIX OR MINGW )$/if( ( UNIX OR MINGW ) AND NOT CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64|ARM64" )/' \
      "$hm_cmake" > "$hm_cmake.tmp" && mv "$hm_cmake.tmp" "$hm_cmake"
fi
if grep -q 'warnings-as-errors' "$hm_cmake"; then
  echo "warnings are still errors in $hm_cmake" >&2; exit 1
fi
grep -Eq '^if\( \(? ?\(? ?UNIX OR MINGW ?\)? ?\)? AND NOT \(? ?CMAKE_SYSTEM_PROCESSOR MATCHES "arm64\|aarch64\|ARM64" ?\)? ?\)$' "$hm_cmake" \
  || { echo "the -msse4.1 option is not guarded in $hm_cmake" >&2; exit 1; }

# The executables are written to bin/ in the sources, in a directory named
# after the generator, the compiler and the configuration.
rm -rf "$SOURCE/bin" "$BUILD"

# OpenMP and ccache are looked up unconditionally. HM has no OpenMP code, and
# linking the OpenMP runtime the build machine has (Homebrew, llvm-mingw) would
# add a dynamic library, so both are turned off.
msg "configuring $HM_TAG for $TARGET"
# shellcheck disable=SC2086
cmake -S "$SOURCE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS_ARGS \
  -DHIGH_BITDEPTH=ON -DEXTENSION_360_VIDEO=OFF -DSET_ENABLE_TRACING=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_OpenMP=ON -DCCACHE_FOUND=OFF \
  "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"

msg "building $TOOLS"
# shellcheck disable=SC2086
cmake --build "$BUILD" --parallel "$JOBS" --target $TOOLS

OUTPUTS=""
for tool in $TOOLS; do
  # On Linux the build also leaves a copy named <tool>Static in bin/.
  built="$(find "$SOURCE/bin" -type f -name "$tool$EXE" | sed -n 1p)"
  [ -n "$built" ] || { echo "$tool$EXE was not built in $SOURCE/bin" >&2; exit 1; }
  out="$WORKDIR/${tool}SCM-$TARGET$EXE"
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
msg "built the SCM $TOOLS for $TARGET"
