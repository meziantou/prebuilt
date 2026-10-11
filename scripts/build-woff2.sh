#!/usr/bin/env bash
#
# Builds statically linked woff2_compress/woff2_decompress/woff2_info from the
# google/woff2 sources.
#
#   bash scripts/build-woff2.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# woff2 is built from a commit of its master branch: its last tag, v1.0.2, is
# from 2017 and misses the bounds-check fixes and the build fixes for current
# compilers that master has. It publishes no binaries.
#
# brotli is the version ffmpeg and the libjxl tools are built with. This script
# has its own prefix, as scripts/build-libjxl.sh does.
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
for name in BROTLI_VERSION WOFF2_COMMIT; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
PREFIX="$WORKDIR/woff2-deps"
SRCDIR="$WORKDIR/woff2-src"
STAMPDIR="$PREFIX/.stamps"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS="woff2_compress woff2_decompress woff2_info"

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
  cmake -S "$src" -B "$WORKDIR/build-woff2-$name" $CMAKE_COMMON $CMAKE_CROSS_ARGS "$@"
  cmake --build "$WORKDIR/build-woff2-$name" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-woff2-$name"
  purge_shared_libs
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

if ! stamp_done "brotli-$BROTLI_VERSION"; then
  fetch brotli "https://github.com/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz" \
        "brotli-$BROTLI_VERSION.tar.gz" "brotli-$BROTLI_VERSION"
  run_cmake brotli "$SRCDIR/brotli-$BROTLI_VERSION" -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUILD_TOOLS=OFF
  stamp_mark "brotli-$BROTLI_VERSION"
fi

for library in brotlicommon brotlidec brotlienc; do
  [ -f "$PREFIX/lib/lib$library.a" ] || { echo "no static $library in $PREFIX/lib" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# woff2
# ---------------------------------------------------------------------------

WOFF2_SOURCE="$SRCDIR/woff2-$WOFF2_COMMIT"
fetch woff2 "https://github.com/google/woff2/archive/$WOFF2_COMMIT.tar.gz" \
      "woff2-$WOFF2_COMMIT.tar.gz" "woff2-$WOFF2_COMMIT"

# The modules woff2 finds brotli with return libbrotlidec and libbrotlienc
# without libbrotlicommon, which a static link needs after them, so both
# variables are set from here.
#
# CMAKE_POLICY_VERSION_MINIMUM: woff2 asks for CMake 2.8.6, which CMake 4 refuses.
# CANONICAL_PREFIXES: when off, -no-canonical-prefixes is passed as a definition.
WOFF2_BUILD="$WORKDIR/build-woff2-woff2"
msg "configuring woff2 $WOFF2_COMMIT for $TARGET"
# shellcheck disable=SC2086
cmake -S "$WOFF2_SOURCE" -B "$WOFF2_BUILD" $CMAKE_COMMON $CMAKE_CROSS_ARGS \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCANONICAL_PREFIXES=ON \
  -DBROTLIDEC_INCLUDE_DIRS:PATH="$PREFIX/include" -DBROTLIENC_INCLUDE_DIRS:PATH="$PREFIX/include" \
  -DBROTLIDEC_LIBRARIES:STRING="$PREFIX/lib/libbrotlidec.a;$PREFIX/lib/libbrotlicommon.a" \
  -DBROTLIENC_LIBRARIES:STRING="$PREFIX/lib/libbrotlienc.a;$PREFIX/lib/libbrotlicommon.a" \
  -DCMAKE_EXE_LINKER_FLAGS="$EXE_LDFLAGS"

msg "building $TOOLS"
# shellcheck disable=SC2086
cmake --build "$WOFF2_BUILD" --parallel "$JOBS" --target $TOOLS

OUTPUTS=""
for tool in $TOOLS; do
  out="$WORKDIR/$tool-$TARGET$EXE"
  cp "$WOFF2_BUILD/$tool$EXE" "$out"
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
