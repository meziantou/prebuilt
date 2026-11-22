#!/usr/bin/env bash
#
# Builds statically linked cjpeg and jpegtran of mozjpeg, the JPEG encoder of
# Mozilla, and names them mozjpeg-cjpeg and mozjpeg-jpegtran: cjpeg and
# jpegtran are also the names of the libjpeg-turbo and IJG tools, which write
# other files.
#
#   bash scripts/build-mozjpeg.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# The mozjpeg releases have Windows binaries only, linked with a DLL of libpng
# for some of them. Every target is built from the tag of the release with its
# CMake build: the static library of mozjpeg with its SIMD code (NASM on x64,
# Neon on arm64), and cjpeg with libpng, so that it reads PNG files next to
# PPM, BMP, Targa, GIF and JPEG files. zlib and libpng are the versions ffmpeg
# and the HarfBuzz tools are built with. TurboJPEG, djpeg, rdjpgcom and
# wrjpgcom are not published.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively. The x64 targets
# need nasm.
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
for name in ZLIB_VERSION LIBPNG_VERSION MOZJPEG_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
PREFIX="$WORKDIR/mozjpeg-deps"
SRCDIR="$WORKDIR/mozjpeg-src"
STAMPDIR="$PREFIX/.stamps"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
    # Links libunwind and winpthreads statically.
    EXE_LDFLAGS="-static"
    STRIP="$MINGW_TRIPLE-strip"
    ;;
  osx-arm64)
    # macOS has no static libSystem: the goal here is "no non-system dylibs".
    export CC=clang CXX=clang++
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
  cmake -S "$src" -B "$WORKDIR/build-mozjpeg-$name" $CMAKE_COMMON $CMAKE_CROSS_ARGS "$@"
  cmake --build "$WORKDIR/build-mozjpeg-$name" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-mozjpeg-$name"
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

# Targeting MinGW, zlib's CMake build installs libzs.a, but zlib.pc advertises
# -lz, which is what libpng links.
if [ ! -f "$PREFIX/lib/libz.a" ]; then
  for zlib_candidate in libzs.a libzlibstatic.a; do
    if [ -f "$PREFIX/lib/$zlib_candidate" ]; then
      cp "$PREFIX/lib/$zlib_candidate" "$PREFIX/lib/libz.a"
      break
    fi
  done
fi
[ -f "$PREFIX/lib/libz.a" ] || { echo "no static zlib in $PREFIX/lib" >&2; exit 1; }

if ! stamp_done "libpng-$LIBPNG_VERSION"; then
  fetch libpng "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG_VERSION.tar.gz" \
        "libpng-$LIBPNG_VERSION.tar.gz" "libpng-$LIBPNG_VERSION"
  run_cmake libpng "$SRCDIR/libpng-$LIBPNG_VERSION" \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
    -DZLIB_LIBRARY="$PREFIX/lib/libz.a" -DZLIB_INCLUDE_DIR="$PREFIX/include"
  stamp_mark "libpng-$LIBPNG_VERSION"
fi
[ -f "$PREFIX/lib/libpng16.a" ] || { echo "no static libpng in $PREFIX/lib" >&2; exit 1; }

# ---------------------------------------------------------------------------
# mozjpeg
# ---------------------------------------------------------------------------

MOZJPEG_SOURCE="$SRCDIR/mozjpeg-$MOZJPEG_VERSION"
fetch mozjpeg "https://github.com/mozilla/mozjpeg/archive/refs/tags/v$MOZJPEG_VERSION.tar.gz" \
      "mozjpeg-$MOZJPEG_VERSION.tar.gz" "mozjpeg-$MOZJPEG_VERSION"

# - ENABLE_SHARED=OFF: the programs are linked with the static library only,
#   and named cjpeg-static and jpegtran-static.
# - CMakeLists.txt asks for CMake 2.8.12, which CMake 4 refuses without
#   CMAKE_POLICY_VERSION_MINIMUM.
# - For cjpeg, CMakeLists.txt clears PNG_LIBRARY and ZLIB_LIBRARY and finds
#   the static libraries again: CMAKE_PREFIX_PATH puts the prefix first, and
#   it has no shared library. The check after the configure step makes sure
#   that the libraries of the prefix are the ones in the link.
# - REQUIRE_SIMD: fail rather than build without the SIMD code, which is what
#   happens when nasm is missing on x64.
MOZJPEG_BUILD="$WORKDIR/build-mozjpeg-mozjpeg"
msg "configuring mozjpeg $MOZJPEG_VERSION for $TARGET"
# shellcheck disable=SC2086
cmake -S "$MOZJPEG_SOURCE" -B "$MOZJPEG_BUILD" $CMAKE_COMMON $CMAKE_CROSS_ARGS \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DPNG_SUPPORTED=ON \
  -DWITH_TURBOJPEG=OFF -DWITH_JAVA=OFF -DWITH_SIMD=ON -DREQUIRE_SIMD=ON \
  -DCMAKE_EXE_LINKER_FLAGS="$EXE_LDFLAGS"

# FindPNG returns libpng.a, the link libpng installs to libpng16.a.
for library in "$PREFIX/lib/libpng" "$PREFIX/lib/libz.a"; do
  grep -q -F "$library" "$MOZJPEG_BUILD/build.ninja" \
    || { echo "cjpeg is not linked with $library" >&2; exit 1; }
done

msg "building cjpeg and jpegtran"
cmake --build "$MOZJPEG_BUILD" --parallel "$JOBS" --target cjpeg-static jpegtran-static

msg "stripping"
for tool in cjpeg jpegtran; do
  out="$WORKDIR/mozjpeg-$tool-$TARGET$EXE"
  cp "$MOZJPEG_BUILD/$tool-static$EXE" "$out"
  $STRIP "$out"
  chmod +x "$out"
  ls -lh "$out"
done

msg "built mozjpeg-cjpeg and mozjpeg-jpegtran for $TARGET"
