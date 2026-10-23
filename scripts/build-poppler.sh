#!/usr/bin/env bash
#
# Builds statically linked pdftoppm, pdftotext, pdffonts, pdfinfo and pdfsig,
# command-line tools of Poppler.
#
#   bash scripts/build-poppler.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# Poppler publishes source releases only: every target is built from them,
# with the libraries of scripts/pdf-libs.sh: zlib, libjpeg-turbo, libpng,
# brotli, FreeType, LittleCMS 2, OpenJPEG, and NSS (with NSPR), the signature
# backend of pdfsig.
#
# The font configuration is "generic" on every target: no fontconfig, and no
# Windows font lookup. A font a file does not embed is drawn with the URW
# base 35 Type 1 fonts when they are in one of the Ghostscript font
# directories Poppler knows (/usr/share/ghostscript/fonts, ...), and not drawn
# otherwise; the tools behave the same on every machine that does not have
# them. Without the poppler-data files, CJK text without an embedded CMap is
# not decoded either.
#
# win-x64 has no pdfsig: NSS builds static libraries with its gyp build only,
# which targets MSVC on Windows, and its makefiles, which MinGW builds use,
# link softoken and freebl as DLLs. The other tools are built without NSS.
#
# Left out: the Qt, GLib and C++ wrappers, cairo (no pdftocairo), libcurl,
# libtiff (no TIFF output), Boost, GPGME, and HarfBuzz (font subsetting when
# signing or filling forms).
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# Versions come from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

TOOL_ID=poppler
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"
. "$SCRIPT_DIR/pdf-libs.sh"

require_versions POPPLER_VERSION ZLIB_VERSION LIBJPEG_TURBO_VERSION LIBPNG_VERSION BROTLI_VERSION \
  FREETYPE_VERSION LCMS2_VERSION OPENJPEG_VERSION

if [ "$TARGET" = "win-x64" ]; then
  TOOLS="pdftoppm pdftotext pdffonts pdfinfo"
  WITH_NSS=OFF
else
  require_versions NSS_VERSION NSPR_VERSION
  TOOLS="pdftoppm pdftotext pdffonts pdfinfo pdfsig"
  WITH_NSS=ON
fi

build_zlib
build_libjpeg_turbo
build_libpng
build_brotli
build_freetype
build_lcms2
build_openjpeg_lib
if [ "$WITH_NSS" = ON ]; then
  build_nspr_nss
fi

# ---------------------------------------------------------------------------
# Poppler
# ---------------------------------------------------------------------------

fetch poppler "https://poppler.freedesktop.org/poppler-$POPPLER_VERSION.tar.xz" \
      "poppler-$POPPLER_VERSION.tar.xz" "poppler-$POPPLER_VERSION"

# The utilities look gettext and libintl up with include(), which
# CMAKE_DISABLE_FIND_PACKAGE_* does not turn off, and pdfsig links the libintl
# found, Homebrew's on macOS. pdfsig prints its messages untranslated then.
POPPLER_UTILS_CMAKELISTS="$SRCDIR/poppler-$POPPLER_VERSION/utils/CMakeLists.txt"
sed -e '/^include(FindGettext)$/d' -e '/^include(FindIntl)$/d' "$POPPLER_UTILS_CMAKELISTS" > "$POPPLER_UTILS_CMAKELISTS.patched"
mv "$POPPLER_UTILS_CMAKELISTS.patched" "$POPPLER_UTILS_CMAKELISTS"
if grep -E '^include\(Find(Gettext|Intl)\)' "$POPPLER_UTILS_CMAKELISTS"; then
  echo "the gettext lookups of $POPPLER_UTILS_CMAKELISTS were not removed" >&2; exit 1
fi

# The libraries Poppler can use but must not are turned off or hidden: a
# library of the build machine (Homebrew's gettext, cairo, ...) would end up in
# the link.
POPPLER_BUILD="$WORKDIR/build-poppler-poppler"
msg "configuring Poppler $POPPLER_VERSION for $TARGET"
# shellcheck disable=SC2086
cmake -S "$SRCDIR/poppler-$POPPLER_VERSION" -B "$POPPLER_BUILD" $CMAKE_COMMON $CMAKE_CROSS_ARGS \
  -DFONT_CONFIGURATION=generic -DENABLE_RELOCATABLE=OFF \
  -DENABLE_UTILS=ON -DENABLE_CPP=OFF -DENABLE_GLIB=OFF -DENABLE_GOBJECT_INTROSPECTION=OFF \
  -DENABLE_QT5=OFF -DENABLE_QT6=OFF -DENABLE_LIBCURL=OFF -DENABLE_LIBTIFF=OFF -DENABLE_BOOST=OFF \
  -DENABLE_GPGME=OFF -DENABLE_HARFBUZZ=OFF -DENABLE_NSS3="$WITH_NSS" -DENABLE_LCMS=ON -DENABLE_LIBOPENJPEG=ON \
  -DENABLE_LIBJPEG=ON -DENABLE_BROTLI=ON -DENABLE_ZLIB_UNCOMPRESS=OFF \
  -DBUILD_MANUAL_TESTS=OFF -DBUILD_GTK_TESTS=OFF -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF \
  -DBUILD_CPP_TESTS=OFF -DRUN_GPERF_IF_PRESENT=OFF -DENABLE_UNSTABLE_API_ABI_HEADERS=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_Cairo=ON -DCMAKE_DISABLE_FIND_PACKAGE_Gettext=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_Intl=ON -DCMAKE_DISABLE_FIND_PACKAGE_GLIB=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_GTK=ON -DCMAKE_DISABLE_FIND_PACKAGE_Fontconfig=ON \
  -DCMAKE_EXE_LINKER_FLAGS="$EXE_LDFLAGS"

# What the configuration found is written to these headers, as 0 or 1.
poppler_headers="$POPPLER_BUILD/config.h $POPPLER_BUILD/poppler/poppler-config.h"
# shellcheck disable=SC2086
config_value() { sed -n "s/^#define $1 \([01]\)\$/\1/p" $poppler_headers; }
for feature in ENABLE_LIBOPENJPEG ENABLE_LIBJPEG ENABLE_LIBPNG USE_CMS ENABLE_BROTLI; do
  [ "$(config_value "$feature")" = 1 ] || { echo "Poppler is configured without $feature" >&2; exit 1; }
done
expected_nss=0
if [ "$WITH_NSS" = ON ]; then expected_nss=1; fi
[ "$(config_value ENABLE_NSS3)" = "$expected_nss" ] || { echo "ENABLE_NSS3 is not $expected_nss" >&2; exit 1; }
for feature in ENABLE_LIBCURL ENABLE_LIBTIFF ENABLE_GPGME WITH_FONTCONFIGURATION_FONTCONFIG WITH_FONTCONFIGURATION_WIN32; do
  [ "$(config_value "$feature")" = 0 ] || { echo "Poppler is configured with $feature" >&2; exit 1; }
done

msg "building $TOOLS"
# shellcheck disable=SC2086
cmake --build "$POPPLER_BUILD" --parallel "$JOBS" --target $TOOLS

OUTPUTS=""
for tool in $TOOLS; do
  built="$POPPLER_BUILD/utils/$tool$EXE"
  [ -f "$built" ] || { echo "$tool$EXE was not built in $POPPLER_BUILD/utils" >&2; exit 1; }
  out="$WORKDIR/$tool-$TARGET$EXE"
  cp "$built" "$out"
  OUTPUTS="$OUTPUTS $out"
done

# shellcheck disable=SC2086
finish_outputs $OUTPUTS
msg "built $TOOLS for $TARGET"
