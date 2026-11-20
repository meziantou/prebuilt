#!/usr/bin/env bash
#
# Builds a statically linked magick, the command-line tool of ImageMagick 7,
# from its sources, as the writer and a reader of PSD and PSB files:
#
#   magick-<target>[.exe]
#
#   bash scripts/build-imagemagick.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# ImageMagick publishes dynamically linked builds only (and an AppImage for
# x64 Linux), with dozens of delegate libraries. This one is built with what
# PSD files need, and the formats to feed it the source images: zlib (the ZIP
# compression of PSD layers, PNG and TIFF), LittleCMS 2 (ICC profiles), libpng
# and libtiff (built with zlib only: no JPEG, JBIG, LZMA, ZSTD, WebP or LERC
# compression). The formats ImageMagick has without a library are there too
# (PNM, BMP, raw samples such as rgb:, gray: and cmyk:, ...). There is no X11,
# OpenMP, OpenCL, threads, C++ API (Magick++), Perl, fonts, Ghostscript or any
# other delegate.
#
# ImageMagick is built with its default quantum: 16 bits with HDRI (floats),
# so that 32-bit (float) PSD files are read without clamping to 16 bits.
# --without-modules links every coder into the executable, and
# --enable-zero-configuration builds the configuration files (delegates.xml,
# policy.xml, ...) into it: the executable needs no other file. Without OpenMP
# and threads, every operation gives the same samples on every target.
#
# zlib, libpng and LittleCMS 2 are the versions the other tools are built with.
# This script has its own prefix, as scripts/build-zbar.sh does.
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
for name in ZLIB_VERSION LIBPNG_VERSION LCMS2_VERSION LIBTIFF_VERSION IMAGEMAGICK_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
PREFIX="$WORKDIR/imagemagick-deps"
SRCDIR="$WORKDIR/imagemagick-src"
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
# -all-static: libtool drops -static from the link of an executable.
LIBTOOL_LDFLAGS=""
STRIP="strip"

case "$TARGET" in
  linux-*)
    # Same compiler as the ffmpeg build.
    export CC=clang CXX=clang++
    LIBTOOL_LDFLAGS="-all-static"
    ;;
  win-x64)
    EXE=".exe"
    [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
    export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
    MINGW_TRIPLE="x86_64-w64-mingw32"
    CMAKE_CROSS_ARGS="-DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/mingw-toolchain.cmake -DMINGW_TRIPLE=$MINGW_TRIPLE"
    CONFIGURE_HOST="--host=$MINGW_TRIPLE"
    # Links libc++, libunwind and winpthreads statically.
    LIBTOOL_LDFLAGS="-all-static"
    STRIP="$MINGW_TRIPLE-strip"
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
# needed too: libtiff.a does not link without libz.a.
export PKG_CONFIG="pkg-config --static"

CMAKE_COMMON="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=OFF"

# run_cmake <name> <source dir> [extra cmake args...]
run_cmake() {
  name="$1"; src="$2"; shift 2
  msg "building $name"
  # shellcheck disable=SC2086
  cmake -S "$src" -B "$WORKDIR/build-imagemagick-$name" $CMAKE_COMMON $CMAKE_CROSS_ARGS "$@"
  cmake --build "$WORKDIR/build-imagemagick-$name" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-imagemagick-$name"
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
# -lz, which is what libpng, libtiff and ImageMagick link.
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

if ! stamp_done "lcms2-$LCMS2_VERSION"; then
  fetch lcms2 "https://github.com/mm2/Little-CMS/releases/download/2.11/lcms2-$LCMS2_VERSION.tar.gz" \
        "lcms2-$LCMS2_VERSION.tar.gz" "lcms2-$LCMS2_VERSION"
  run_cmake lcms2 "$SRCDIR/lcms2-$LCMS2_VERSION" \
    -DLCMS2_BUILD_SHARED=OFF -DLCMS2_BUILD_STATIC=ON -DLCMS2_BUILD_TOOLS=OFF -DLCMS2_BUILD_TESTS=OFF \
    -DLCMS2_WITH_JPEG=OFF -DLCMS2_WITH_TIFF=OFF -DLCMS2_WITH_ZLIB=OFF
  stamp_mark "lcms2-$LCMS2_VERSION"
fi
[ -f "$PREFIX/lib/liblcms2.a" ] || { echo "no static LittleCMS 2 in $PREFIX/lib" >&2; exit 1; }

# libtiff, with the compressions it has without a library and zlib (Deflate,
# PixarLog): no JPEG, old JPEG, JBIG, LZMA, ZSTD, WebP, LERC or libdeflate,
# and no tools or C++ API.
if ! stamp_done "libtiff-$LIBTIFF_VERSION"; then
  fetch libtiff "https://download.osgeo.org/libtiff/tiff-$LIBTIFF_VERSION.tar.gz" \
        "tiff-$LIBTIFF_VERSION.tar.gz" "tiff-$LIBTIFF_VERSION"
  run_cmake libtiff "$SRCDIR/tiff-$LIBTIFF_VERSION" \
    -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF -Dtiff-deprecated=OFF \
    -Dcxx=OFF -Dzlib=ON -Dlibdeflate=OFF -Dpixarlog=ON -Djpeg=OFF -Dold-jpeg=OFF -Djpeg12=OFF \
    -Djbig=OFF -Dlerc=OFF -Dlzma=OFF -Dzstd=OFF -Dwebp=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_OpenGL=ON -DCMAKE_DISABLE_FIND_PACKAGE_GLUT=ON
  stamp_mark "libtiff-$LIBTIFF_VERSION"
fi
[ -f "$PREFIX/lib/libtiff.a" ] || { echo "no static libtiff in $PREFIX/lib" >&2; exit 1; }

# ---------------------------------------------------------------------------
# ImageMagick
# ---------------------------------------------------------------------------

# The release tags are <version>-<patch level>: 7.1.2-35. The tag archive has
# the generated configure script.
fetch ImageMagick "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/$IMAGEMAGICK_VERSION.tar.gz" \
      "ImageMagick-$IMAGEMAGICK_VERSION.tar.gz" "ImageMagick-$IMAGEMAGICK_VERSION"
IM_SOURCE="$SRCDIR/ImageMagick-$IMAGEMAGICK_VERSION"

# Every optional library is turned off, so that nothing is picked up because
# the build machine has it. --without-gdi32: no clipboard or EMF coders on
# Windows. --disable-installed: no path of the build machine is compiled in.
IM_BUILD="$WORKDIR/build-imagemagick-imagemagick"
msg "configuring ImageMagick $IMAGEMAGICK_VERSION for $TARGET"
rm -rf "$IM_BUILD"
mkdir -p "$IM_BUILD"
# shellcheck disable=SC2086
( cd "$IM_BUILD" \
  && CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
     "$IM_SOURCE/configure" $CONFIGURE_HOST --prefix="$PREFIX" \
       --disable-shared --enable-static --without-modules --enable-zero-configuration --disable-installed \
       --disable-openmp --disable-opencl --without-threads --enable-hdri --with-quantum-depth=16 \
       --disable-docs --disable-dependency-tracking --without-magick-plus-plus --without-perl --without-x \
       --with-utilities --with-security-policy=open \
       --with-zlib --with-lcms --with-png --with-tiff \
       --without-bzlib --without-zip --without-zstd --without-autotrace --without-dps --without-fftw \
       --without-flif --without-fpx --without-djvu --without-fontconfig --without-freetype --without-raqm \
       --without-gdi32 --without-gslib --without-gvc --without-dmr --without-heic --without-jbig \
       --without-jpeg --without-jxl --without-openjp2 --without-lqr --without-lzma --without-openexr \
       --without-pango --without-raw --without-rsvg --without-uhdr --without-webp --without-wmf \
       --without-xml --without-jemalloc --without-tcmalloc --without-umem )

# configure must have found the four libraries, and nothing else. A Windows
# build always lists ps: it looks for a Ghostscript DLL when it reads
# PostScript or PDF, and links no library for it.
summary="$(sed -n 's/^MAGICK_DELEGATES *= *//p' "$IM_BUILD/Makefile" | head -n 1)"
msg "delegates: $summary"
for delegate in lcms png tiff zlib; do
  case " $summary " in
    *" $delegate "*) ;;
    *) echo "ImageMagick was configured without $delegate: $summary" >&2; exit 1 ;;
  esac
done
for delegate in $summary; do
  case "$TARGET-$delegate" in
    *-lcms|*-png|*-tiff|*-zlib|win-x64-ps) ;;
    *) echo "ImageMagick was configured with the unexpected delegate $delegate" >&2; exit 1 ;;
  esac
done

msg "building magick"
# The static link of the utility needs the private dependencies of libtiff and
# libpng, which libtool takes from the .la files of ImageMagick.
make -C "$IM_BUILD" -j"$JOBS" LDFLAGS="-L$PREFIX/lib $LIBTOOL_LDFLAGS" "utilities/magick$EXE"

out="$WORKDIR/magick-$TARGET$EXE"
cp "$IM_BUILD/utilities/magick$EXE" "$out"

msg "stripping"
$STRIP "$out"
chmod +x "$out"

ls -lh "$out"
msg "built magick for $TARGET"
