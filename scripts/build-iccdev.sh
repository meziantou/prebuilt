#!/usr/bin/env bash
#
# Builds statically linked command-line tools of iccDEV (formerly DemoIccMAX,
# https://github.com/InternationalColorConsortium/iccDEV), the reference
# implementation of iccMAX (ICC.2, version 5 profiles) of the International
# Color Consortium, from the release tag:
#
#   iccFromXml, iccToXml, iccFromJson, iccToJson, iccDumpProfile,
#   iccRoundTrip, iccApplyNamedCmm, iccApplyToLink: <tool>-<target>[.exe]
#
#   bash scripts/build-iccdev.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# The release has dynamically linked tools for some targets only. They are
# built here with libxml2 (the XML tools; without iconv, zlib or LZMA),
# nlohmann_json (the JSON tools) and zlib (compressed text tags), and without
# the image tools (libtiff, libpng, libjpeg), the GUI (wxWidgets), the Windows
# CMM and ISAPI DLLs, and the AVX2 code, so that every target computes the
# same values.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# ICCDEV_VERSION, ICCDEV_LIBRARY_VERSION, LIBXML2_VERSION, NLOHMANN_JSON_VERSION
# and ZLIB_VERSION come from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

TOOL_ID=iccdev
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"
. "$SCRIPT_DIR/pdf-libs.sh"

require_versions ICCDEV_VERSION ICCDEV_LIBRARY_VERSION LIBXML2_VERSION NLOHMANN_JSON_VERSION
TOOLS="iccFromXml iccToXml iccFromJson iccToJson iccDumpProfile iccRoundTrip iccApplyNamedCmm iccApplyToLink"

build_zlib

if ! stamp_done "libxml2-$LIBXML2_VERSION"; then
  libxml2_minor="$(echo "$LIBXML2_VERSION" | cut -d . -f 1-2)"
  fetch libxml2 "https://download.gnome.org/sources/libxml2/$libxml2_minor/libxml2-$LIBXML2_VERSION.tar.xz" \
        "libxml2-$LIBXML2_VERSION.tar.xz" "libxml2-$LIBXML2_VERSION"
  run_cmake libxml2 "$SRCDIR/libxml2-$LIBXML2_VERSION" \
    -DLIBXML2_WITH_ICONV=OFF -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_ZLIB=OFF \
    -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF -DLIBXML2_WITH_HTTP=OFF \
    -DLIBXML2_WITH_MODULES=OFF -DLIBXML2_WITH_THREADS=ON -DLIBXML2_WITH_DOCS=OFF
  stamp_mark "libxml2-$LIBXML2_VERSION"
fi
[ -f "$PREFIX/lib/libxml2.a" ] || { echo "no static libxml2 in $PREFIX/lib" >&2; exit 1; }

if ! stamp_done "nlohmann-json-$NLOHMANN_JSON_VERSION"; then
  fetch nlohmann_json "https://github.com/nlohmann/json/archive/refs/tags/v$NLOHMANN_JSON_VERSION.tar.gz" \
        "json-$NLOHMANN_JSON_VERSION.tar.gz" "json-$NLOHMANN_JSON_VERSION"
  run_cmake nlohmann-json "$SRCDIR/json-$NLOHMANN_JSON_VERSION" -DJSON_BuildTests=OFF -DJSON_Install=ON
  stamp_mark "nlohmann-json-$NLOHMANN_JSON_VERSION"
fi

fetch iccDEV "https://github.com/InternationalColorConsortium/iccDEV/archive/refs/tags/v$ICCDEV_VERSION.tar.gz" \
      "iccDEV-$ICCDEV_VERSION.tar.gz" "iccDEV-$ICCDEV_VERSION"
SOURCE="$SRCDIR/iccDEV-$ICCDEV_VERSION"
# The tools print ICCPROFLIBVER, which is not always the version of the tag.
grep -q "^#define ICCPROFLIBVER \"$ICCDEV_LIBRARY_VERSION\"" "$SOURCE/IccProfLib/IccProfLibVer.h" \
  || { echo "ICCPROFLIBVER of iccDEV $ICCDEV_VERSION is not $ICCDEV_LIBRARY_VERSION" >&2; exit 1; }

BUILD="$WORKDIR/build-iccdev"
msg "configuring iccDEV $ICCDEV_VERSION for $TARGET"
rm -rf "$BUILD"
# The libxml2 of the prefix is static: its users need -DLIBXML_STATIC on
# Windows. iccDEV uses std::nothrow, malloc, memcpy, ... without including
# their headers, which the libc++ of llvm-mingw does not include from the
# other headers.
CXX_DEFINES=""
C_DEFINES=""
LINK_FLAGS="$EXE_LDFLAGS"
STANDARD_LIBRARIES=""
if [ "$TARGET" = win-x64 ]; then
  C_DEFINES="-DLIBXML_STATIC"
  CXX_DEFINES="-DLIBXML_STATIC -include new -include cstdlib -include cstring"
  # libxml2 seeds its hash tables with BCryptGenRandom: bcrypt comes after the
  # static libraries.
  STANDARD_LIBRARIES="-DCMAKE_CXX_STANDARD_LIBRARIES=-lbcrypt"
fi
# shellcheck disable=SC2086
cmake -S "$SOURCE/Build/Cmake" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS_ARGS \
  -DCMAKE_PREFIX_PATH="$PREFIX" -DENABLE_SHARED_LIBS=OFF -DENABLE_STATIC_LIBS=ON -DENABLE_TESTS=OFF \
  -DENABLE_TOOLS=ON -DENABLE_WXWIDGETS=OFF -DENABLE_IMAGE_TOOLS=OFF -DENABLE_CMM_TOOLS=OFF -DENABLE_IIS_TOOLS=OFF \
  -DENABLE_ICCXML=ON -DENABLE_ICCJSON=ON -DICC_USE_ZLIB=ON -DICCDEV_ENABLE_AVX2=OFF -DICCDEV_ENABLE_AVX512=OFF \
  -DICCDEV_ENABLE_TELEMETRY=OFF -DENABLE_SANITIZERS=OFF -DENABLE_FUZZING=OFF \
  "-DCMAKE_CXX_FLAGS=$CXX_DEFINES" "-DCMAKE_C_FLAGS=$C_DEFINES" \
  "-DCMAKE_EXE_LINKER_FLAGS=$LINK_FLAGS" ${STANDARD_LIBRARIES:+"$STANDARD_LIBRARIES"}

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
