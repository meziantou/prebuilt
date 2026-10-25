#!/usr/bin/env bash
#
# Builds a statically linked zbarimg, the image scanner of the ZBar bar code
# reader, from its sources.
#
#   bash scripts/build-zbar.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# ZBar publishes dynamically linked builds only, for x64. zbarimg reads its
# images with GraphicsMagick (MagickWand), which is built here with PNG and
# zlib only, without modules, OpenMP, threads or any delegate library: zbarimg
# reads PNG and the formats GraphicsMagick has without a library (PNM, BMP,
# GIF, TGA, ...), not JPEG or TIFF. ZBar is built with the symbologies it
# enables by default (EAN/UPC with their add-ons, DataBar, Code 128, Code 93,
# Code 39, Codabar, Interleaved 2 of 5, QR Code and SQ Code), without video,
# X11, D-Bus, GTK, Qt, Python, Java and translations.
#
# The QR Code decoder needs iconv: the C library has it on Linux (musl) and
# macOS; GNU libiconv is built for win-x64. zlib and libpng are the versions
# ffmpeg and the HarfBuzz tools are built with. This script has its own
# prefix, as scripts/build-libjxl.sh does.
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
for name in ZLIB_VERSION LIBPNG_VERSION LIBICONV_VERSION GRAPHICSMAGICK_VERSION ZBAR_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
PREFIX="$WORKDIR/zbar-deps"
SRCDIR="$WORKDIR/zbar-src"
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
      case "$out" in
        *.tar.xz) tar -tJf "$out" >/dev/null 2>&1 && return 0 ;;
        *)        tar -tzf "$out" >/dev/null 2>&1 && return 0 ;;
      esac
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
CONFIGURE_HOST=""
MESON_TARGET_ARGS=""
ZBAR_PTHREAD=false
STRIP="strip"

case "$TARGET" in
  linux-*)
    # Same compiler as the ffmpeg build.
    export CC=clang CXX=clang++
    MESON_TARGET_ARGS="-Dc_link_args=-static -Dcpp_link_args=-static"
    ;;
  win-x64)
    EXE=".exe"
    [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
    export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
    MINGW_TRIPLE="x86_64-w64-mingw32"
    export MINGW_TRIPLE
    CMAKE_CROSS_ARGS="-DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/mingw-toolchain.cmake -DMINGW_TRIPLE=$MINGW_TRIPLE"
    CONFIGURE_HOST="--host=$MINGW_TRIPLE"
    STRIP="$MINGW_TRIPLE-strip"
    # The meson cross file is written below.
    ;;
  osx-arm64)
    # macOS has no static libSystem: the goal here is "no non-system dylibs".
    STRIP="strip -x"
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    ;;
esac

# pkg-config must see the prefix and nothing else, so that Homebrew cannot leak
# a .dylib into the link.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
# Everything in the prefix is a static library, whose private dependencies are
# needed too: libGraphicsMagickWand.a does not link without libpng16.a. meson's
# prefer_static option is not used for that, as for scripts/build-harfbuzz.sh:
# it also asks for a static iconv, which macOS does not have. The cross file
# does the same for win-x64.
export PKG_CONFIG="pkg-config --static"

CMAKE_COMMON="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=OFF"

# run_cmake <name> <source dir> [extra cmake args...]
run_cmake() {
  name="$1"; src="$2"; shift 2
  msg "building $name"
  # shellcheck disable=SC2086
  cmake -S "$src" -B "$WORKDIR/build-zbar-$name" $CMAKE_COMMON $CMAKE_CROSS_ARGS "$@"
  cmake --build "$WORKDIR/build-zbar-$name" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-zbar-$name"
  purge_shared_libs
}

# run_configure <name> <source dir> [extra configure args...]: an out-of-tree
# autotools build, installed into the prefix.
run_configure() {
  name="$1"; src="$2"; shift 2
  msg "building $name"
  rm -rf "$WORKDIR/build-zbar-$name"
  mkdir -p "$WORKDIR/build-zbar-$name"
  # shellcheck disable=SC2086
  ( cd "$WORKDIR/build-zbar-$name" \
    && CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
       "$src/configure" $CONFIGURE_HOST --prefix="$PREFIX" --disable-shared --enable-static "$@" \
    && make -j"$JOBS" \
    && make install )
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
# -lz, which is what libpng and GraphicsMagick link.
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
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
  stamp_mark "libpng-$LIBPNG_VERSION"
fi
[ -f "$PREFIX/lib/libpng16.a" ] || { echo "no static libpng in $PREFIX/lib" >&2; exit 1; }

# GNU libiconv, for the QR Code decoder on Windows only.
if [ "$TARGET" = win-x64 ]; then
  if ! stamp_done "libiconv-$LIBICONV_VERSION"; then
    fetch libiconv "https://ftpmirror.gnu.org/gnu/libiconv/libiconv-$LIBICONV_VERSION.tar.gz" \
          "libiconv-$LIBICONV_VERSION.tar.gz" "libiconv-$LIBICONV_VERSION"
    run_configure libiconv "$SRCDIR/libiconv-$LIBICONV_VERSION" --disable-nls --disable-rpath
    stamp_mark "libiconv-$LIBICONV_VERSION"
  fi
  [ -f "$PREFIX/lib/libiconv.a" ] || { echo "no static libiconv in $PREFIX/lib" >&2; exit 1; }
fi

# GraphicsMagick, the image reader of zbarimg, with PNG and zlib only.
# --without-modules: the coders are linked into the library, so that nothing is
# loaded at run time. --disable-installed: the configuration files are looked
# for next to the executable, not in the prefix or the Windows registry;
# zbarimg needs none of them. --without-threads: zbarimg reads one image at a
# time. Every optional library is turned off, so that nothing is picked up
# because the build machine has it.
if ! stamp_done "graphicsmagick-$GRAPHICSMAGICK_VERSION"; then
  fetch GraphicsMagick "https://downloads.sourceforge.net/project/graphicsmagick/graphicsmagick/$GRAPHICSMAGICK_VERSION/GraphicsMagick-$GRAPHICSMAGICK_VERSION.tar.xz" \
        "GraphicsMagick-$GRAPHICSMAGICK_VERSION.tar.xz" "GraphicsMagick-$GRAPHICSMAGICK_VERSION"
  run_configure graphicsmagick "$SRCDIR/GraphicsMagick-$GRAPHICSMAGICK_VERSION" \
    --without-modules --disable-installed --disable-openmp --without-threads \
    --with-quantum-depth=8 --without-magick-plus-plus --without-perl --without-x \
    --with-png --with-zlib \
    --without-bzlib --without-dps --without-fpx --without-gslib --without-jbig \
    --without-jpeg --without-jxl --without-jp2 --without-lcms2 --without-lzma \
    --without-tiff --without-trio --without-ttf --without-umem --without-webp \
    --without-wmf --without-xml --without-zstd --without-heif --without-libzip
  stamp_mark "graphicsmagick-$GRAPHICSMAGICK_VERSION"
fi
[ -f "$PREFIX/lib/libGraphicsMagickWand.a" ] || { echo "no static GraphicsMagickWand in $PREFIX/lib" >&2; exit 1; }
pkg-config --exists GraphicsMagickWand || { echo "no GraphicsMagickWand.pc in $PKG_CONFIG_LIBDIR" >&2; exit 1; }

# ---------------------------------------------------------------------------
# ZBar
# ---------------------------------------------------------------------------

ZBAR_SOURCE="$SRCDIR/zbar-$ZBAR_VERSION"
fetch zbar "https://linuxtv.org/downloads/zbar/zbar-$ZBAR_VERSION.tar.gz" \
      "zbar-$ZBAR_VERSION.tar.gz" "zbar-$ZBAR_VERSION"

if [ -n "$MINGW_TRIPLE" ]; then
  # -static links libc++, libunwind and winpthreads statically. The
  # static_executables option of ZBar, which does the same, is not used: it
  # asks meson for a static iconv, which meson looks for in the library
  # directories of the compiler only, not in the prefix.
  cat > "$WORKDIR/zbar-cross.txt" <<EOF
[binaries]
c = '$MINGW_TRIPLE-clang'
cpp = '$MINGW_TRIPLE-clang++'
ar = '$MINGW_TRIPLE-ar'
strip = '$MINGW_TRIPLE-strip'
windres = '$MINGW_TRIPLE-windres'
pkg-config = ['pkg-config', '--static']

[built-in options]
c_link_args = ['-static', '-L$PREFIX/lib']
cpp_link_args = ['-static', '-L$PREFIX/lib']

[properties]
pkg_config_libdir = '$PREFIX/lib/pkgconfig'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
  MESON_TARGET_ARGS="--cross-file $WORKDIR/zbar-cross.txt"
  # On Windows, ZBar uses the threads of Windows: the pthread option only links
  # winpthreads, which has the clock_gettime of the MinGW headers.
  ZBAR_PTHREAD=true
  # libiconv has no pkg-config file: meson links it with -liconv and the -L of
  # the cross file, but looks for iconv.h without the arguments of the cross
  # file, so clang finds it in the prefix through CPATH.
  export CPATH="$PREFIX/include"
fi

# auto_features=disabled: nothing is picked up because the build machine has
# it. graphicsmagick=enabled makes ZBar use GraphicsMagickWand, not MagickWand.
# pthread is off but on Windows: zbarimg scans one image at a time.
ZBAR_BUILD="$WORKDIR/build-zbar-zbar"
msg "configuring zbar $ZBAR_VERSION for $TARGET"
rm -rf "$ZBAR_BUILD"
# shellcheck disable=SC2086
meson setup "$ZBAR_BUILD" "$ZBAR_SOURCE" $MESON_TARGET_ARGS \
  --buildtype=release -Dlibrary_type=static -Ddefault_library=static -Dauto_features=disabled \
  -Dimagemagick=enabled -Dgraphicsmagick=enabled \
  -Dvideo=false -Dpthread="$ZBAR_PTHREAD" -Ddoc=false -Dbuild_tests=false \
  -Dgtk=no -Dgir=false -Dqt=false -Dpython=no -Djava=disabled -Dnpapi=disabled \
  -Dnls=disabled -Dx11=disabled -Dxv=disabled -Dxshm=disabled -Ddbus=disabled -Djpeg=disabled

msg "building zbarimg"
meson compile -C "$ZBAR_BUILD" -j "$JOBS" zbarimg

out="$WORKDIR/zbarimg-$TARGET$EXE"
cp "$ZBAR_BUILD/zbarimg/zbarimg$EXE" "$out"

msg "stripping"
$STRIP "$out"
chmod +x "$out"

ls -lh "$out"
msg "built zbarimg for $TARGET"
