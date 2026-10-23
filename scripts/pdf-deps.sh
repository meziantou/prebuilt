# Shared part of the builds of the PDF tools (scripts/build-qpdf.sh, ...):
# helpers, target configuration, and the static libraries they link.
#
# Sourced, not run, after the caller has set:
#   TARGET      linux-x64 | linux-arm64 | win-x64 | osx-arm64
#   TOOL_ID     short name of the build: the prefix is $TOOL_ID-deps, the build
#               directories build-$TOOL_ID-<library>, the sources $TOOL_ID-src
#   SCRIPT_DIR  the scripts directory
#
# Callers source it as `. "$SCRIPT_DIR/pdf-deps.sh"`, so that it is part of
# their build key (scripts/Get-BuildPlan.ps1).
#
# Each library has its own build_<library> function, and is built once per
# prefix (.stamps). The versions come from the environment (see
# .github/workflows/ci.yml); require_versions checks the ones a build needs.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

WORKDIR="$(pwd)"
PREFIX="$WORKDIR/$TOOL_ID-deps"
SRCDIR="$WORKDIR/$TOOL_ID-src"
STAMPDIR="$PREFIX/.stamps"

mkdir -p "$PREFIX" "$SRCDIR" "$STAMPDIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

msg() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# require_versions NAME...: fails when one of the variables is empty.
require_versions() {
  for name in "$@"; do
    eval "value=\${$name}"
    [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
  done
}

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
      tar -tf "$out" >/dev/null 2>&1 && return 0
      echo "downloaded file is not a valid archive: $url" >&2
    fi
    echo "download attempt $attempt failed: $url" >&2
    attempt=$((attempt + 1))
    sleep $((2 * attempt))
  done
  echo "failed to download $url after 5 attempts" >&2
  return 1
}

# fetch <name> <url> <archive> <directory>: downloads and extracts into $SRCDIR.
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
  *)
    echo "unknown target: $TARGET" >&2; exit 2 ;;
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
  cmake -S "$src" -B "$WORKDIR/build-$TOOL_ID-$name" $CMAKE_COMMON $CMAKE_CROSS_ARGS "$@"
  cmake --build "$WORKDIR/build-$TOOL_ID-$name" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-$TOOL_ID-$name"
  purge_shared_libs
}

# finish_outputs <file>...: strips the outputs and makes them executable.
finish_outputs() {
  msg "stripping"
  # shellcheck disable=SC2086
  $STRIP "$@"
  chmod +x "$@"
  ls -lh "$@"
}

# ---------------------------------------------------------------------------
# Libraries
# ---------------------------------------------------------------------------

# zlib, the version ffmpeg and the HarfBuzz tools are built with.
build_zlib() {
  require_versions ZLIB_VERSION
  if ! stamp_done "zlib-$ZLIB_VERSION"; then
    fetch zlib "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" \
          "zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION"
    run_cmake zlib "$SRCDIR/zlib-$ZLIB_VERSION" \
      -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_MINIZIP=OFF
    stamp_mark "zlib-$ZLIB_VERSION"
  fi

  # Targeting MinGW, zlib's CMake build installs libzs.a, but zlib.pc
  # advertises -lz.
  if [ ! -f "$PREFIX/lib/libz.a" ]; then
    for zlib_candidate in libzs.a libzlibstatic.a; do
      if [ -f "$PREFIX/lib/$zlib_candidate" ]; then
        cp "$PREFIX/lib/$zlib_candidate" "$PREFIX/lib/libz.a"
        break
      fi
    done
  fi
  [ -f "$PREFIX/lib/libz.a" ] || { echo "no static zlib in $PREFIX/lib" >&2; exit 1; }
}

# libjpeg-turbo, without its SIMD code: the C code needs no assembler, and
# decodes to the same samples on every target.
build_libjpeg_turbo() {
  require_versions LIBJPEG_TURBO_VERSION
  if ! stamp_done "libjpeg-turbo-$LIBJPEG_TURBO_VERSION"; then
    fetch libjpeg-turbo "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$LIBJPEG_TURBO_VERSION/libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz" \
          "libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz" "libjpeg-turbo-$LIBJPEG_TURBO_VERSION"
    run_cmake libjpeg-turbo "$SRCDIR/libjpeg-turbo-$LIBJPEG_TURBO_VERSION" \
      -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF \
      -DWITH_TESTS=OFF
    stamp_mark "libjpeg-turbo-$LIBJPEG_TURBO_VERSION"
  fi
  [ -f "$PREFIX/lib/libjpeg.a" ] || { echo "no static libjpeg in $PREFIX/lib" >&2; exit 1; }
}
