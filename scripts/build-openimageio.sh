#!/usr/bin/env bash
#
# Builds statically linked oiiotool and iinfo, the command-line tools of
# OpenImageIO (https://github.com/AcademySoftwareFoundation/OpenImageIO), from
# the release tag:
#
#   oiiotool-<target>[.exe], iinfo-<target>[.exe]
#
#   bash scripts/build-openimageio.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# OpenImageIO publishes no binaries. Its built-in readers and writers are
# built (PSD, DPX, Cineon, DDS, HDR, BMP, TGA, PNM, SGI, ICO, IFF, Softimage,
# FITS, Zfile, null...), with libpng, libtiff, OpenEXR, libjpeg-turbo and
# LibRaw (camera raw and DNG), and none of the other optional libraries
# (no GIF, WebP, JPEG XL, HEIF, OpenJPEG, OpenJPH, FFmpeg, FreeType, OpenCV,
# OpenVDB, Ptex, DCMTK, Ultra HDR, Qt, Python, TBB).
#
# The libraries OpenImageIO requires are built by its own CMake build, at the
# versions it pins (OpenImageIO_BUILD_LOCAL_DEPS: Imath, OpenEXR,
# OpenColorIO and its expat, yaml-cpp, pystring and minizip-ng, libtiff,
# libdeflate, zstd, fmt, robin-map), statically. zlib, libjpeg-turbo (without
# its SIMD code), libpng and LittleCMS 2 are the versions the PDF tools are
# built with (scripts/pdf-libs.sh), and LibRaw the one of the LibRaw tools
# (scripts/build-libraw.sh), built into the prefix of this script.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively. The local
# builds of the dependencies are cloned with git.
#
# OPENIMAGEIO_VERSION, LIBRAW_VERSION and the versions of the libraries come
# from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

TOOL_ID=openimageio
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"
. "$SCRIPT_DIR/pdf-libs.sh"

require_versions OPENIMAGEIO_VERSION LIBRAW_VERSION
TOOLS="oiiotool iinfo"

build_zlib
build_libjpeg_turbo
build_libpng
build_lcms2

# LibRaw, as scripts/build-libraw.sh builds it: the library only.
if ! stamp_done "libraw-$LIBRAW_VERSION"; then
  fetch LibRaw "https://www.libraw.org/data/LibRaw-$LIBRAW_VERSION.tar.gz" \
        "LibRaw-$LIBRAW_VERSION.tar.gz" "LibRaw-$LIBRAW_VERSION"
  configure_host=""
  [ "$TARGET" = win-x64 ] && configure_host="--host=$MINGW_TRIPLE"
  rm -rf "$WORKDIR/build-openimageio-libraw"
  mkdir -p "$WORKDIR/build-openimageio-libraw"
  # shellcheck disable=SC2086
  ( cd "$WORKDIR/build-openimageio-libraw" \
    && PKG_CONFIG="pkg-config --static" CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
       "$SRCDIR/LibRaw-$LIBRAW_VERSION/configure" $configure_host --prefix="$PREFIX" --disable-shared --enable-static \
         --disable-openmp --enable-jpeg --enable-zlib --enable-lcms --disable-examples --disable-dependency-tracking \
    && make -j"$JOBS" && make install )
  purge_shared_libs
  stamp_mark "libraw-$LIBRAW_VERSION"
fi
[ -f "$PREFIX/lib/libraw_r.a" ] || [ -f "$PREFIX/lib/libraw.a" ] || { echo "no static LibRaw in $PREFIX/lib" >&2; exit 1; }

fetch OpenImageIO "https://github.com/AcademySoftwareFoundation/OpenImageIO/archive/refs/tags/v$OPENIMAGEIO_VERSION.tar.gz" \
      "OpenImageIO-$OPENIMAGEIO_VERSION.tar.gz" "OpenImageIO-$OPENIMAGEIO_VERSION"
SOURCE="$SRCDIR/OpenImageIO-$OPENIMAGEIO_VERSION"

LOCAL_DEPS="Imath;OpenEXR;OpenColorIO;expat;yaml-cpp;pystring;minizip-ng;TIFF;libdeflate;zstd;fmt;Robinmap"
DISABLED=""
for package in GIF WebP JXL Libheif OpenJPEG openjph FFmpeg Freetype OpenCV OpenVDB Ptex DCMTK TBB libuhdr Qt5 Qt6 \
               Python Python3 pybind11 nanobind R3DSDK Nuke OpenGL BZip2 LibLZMA; do
  DISABLED="$DISABLED -DCMAKE_DISABLE_FIND_PACKAGE_$package=ON"
done

BUILD="$WORKDIR/build-openimageio"
msg "configuring OpenImageIO $OPENIMAGEIO_VERSION for $TARGET"
rm -rf "$BUILD"
# shellcheck disable=SC2086
cmake -S "$SOURCE" -B "$BUILD" $CMAKE_COMMON $CMAKE_CROSS_ARGS $DISABLED \
  -DBUILD_SHARED_LIBS=OFF -DLINKSTATIC=ON -DEMBEDPLUGINS=ON -DOIIO_BUILD_TOOLS=ON -DOIIO_BUILD_TESTS=OFF \
  -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF -DINSTALL_DOCS=OFF -DINSTALL_FONTS=OFF -DUSE_PYTHON=OFF -DUSE_QT=OFF \
  -DUSE_CCACHE=OFF -DUSE_JXL=OFF -DUSE_R3DSDK=OFF -DUSE_EXTERNAL_PUGIXML=OFF -DOIIO_INTERNALIZE_FMT=ON \
  -DUSE_LIBRAW=ON -DLibRaw_ROOT="$PREFIX" -DUSE_OPENCOLORIO=ON \
  "-DOpenImageIO_BUILD_LOCAL_DEPS=$LOCAL_DEPS" -DOpenImageIO_BUILD_MISSING_DEPS="" \
  -DOpenImageIO_DEPENDENCY_BUILD_VERBOSE=OFF \
  "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"

for package in LibRaw PNG TIFF OpenEXR OpenColorIO libjpeg-turbo; do
  grep -q "^${package}_FOUND:\\|^${package}_DIR:" "$BUILD/CMakeCache.txt" || true
done

msg "building $TOOLS"
# shellcheck disable=SC2086
cmake --build "$BUILD" --parallel "$JOBS" --target $TOOLS

OUTPUTS=""
for tool in $TOOLS; do
  built="$(find "$BUILD" -type f -perm -u+x -name "$tool$EXE" | sed -n 1p)"
  [ -n "$built" ] || { echo "$tool$EXE was not built in $BUILD" >&2; exit 1; }
  out="$WORKDIR/$tool-$TARGET$EXE"
  cp "$built" "$out"
  OUTPUTS="$OUTPUTS $out"
done
# shellcheck disable=SC2086
finish_outputs $OUTPUTS
msg "built $TOOLS for $TARGET"
