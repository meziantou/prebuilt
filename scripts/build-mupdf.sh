#!/usr/bin/env bash
#
# Builds a statically linked mutool, the command-line tool of MuPDF.
#
#   bash scripts/build-mupdf.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# MuPDF publishes no mutool binaries: every target is built from the source
# release, which includes the third-party libraries MuPDF is built with
# (FreeType, HarfBuzz, libjpeg, OpenJPEG, jbig2dec, LittleCMS, zlib, brotli,
# MuJS, ...), and the generated sources of its built-in fonts. mutool uses
# those, and no library of the build machine.
#
# Built with its makefiles, with what needs a system library turned off: no
# X11/OpenGL viewer, no curl, no libcrypto (mutool cannot check or create
# digital signatures), no Tesseract OCR. The built-in fonts are all kept, so
# `mutool draw` renders the base 14 fonts and the CJK fallback fonts without
# any system font.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# MUPDF_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
[ -n "$MUPDF_VERSION" ] || { echo "MUPDF_VERSION is not set" >&2; exit 2; }

WORKDIR="$(pwd)"
SRCDIR="$WORKDIR/mupdf-src"
SOURCE="$SRCDIR/mupdf-$MUPDF_VERSION-source"
OUT="$WORKDIR/build-mupdf"

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
STRIP="strip"
# MuPDF's makefiles pick their settings from OS (`uname` by default).
MAKE_ARGS=""

case "$TARGET" in
  linux-*)
    # Same compiler as the ffmpeg build. HarfBuzz and the other C++ libraries
    # are linked with the C driver, so the C++ runtime is named explicitly.
    MAKE_ARGS="OS=Linux CC=clang CXX=clang++ XLDFLAGS=-static XLIBS=-lstdc++"
    ;;
  win-x64)
    EXE=".exe"
    [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
    export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
    MINGW_TRIPLE="x86_64-w64-mingw32"
    # Any OS that is not Linux or Darwin: the fonts are compiled from the
    # generated C sources rather than turned into objects with the linker of
    # the build machine. -static links libc++, libunwind and winpthreads.
    # ARCH_HAS_SSE=0: MuPDF turns its SSE 4.1 deskew code on when _M_X64 is
    # defined, which clang also defines for MinGW, but without the compiler
    # flags that code needs. It is off on Linux x64 and macOS too.
    MAKE_ARGS="OS=MINGW CC=$MINGW_TRIPLE-clang CXX=$MINGW_TRIPLE-clang++ AR=$MINGW_TRIPLE-ar RANLIB=$MINGW_TRIPLE-ranlib XCFLAGS=-DARCH_HAS_SSE=0 XLDFLAGS=-static XLIBS=-lc++"
    STRIP="$MINGW_TRIPLE-strip"
    ;;
  osx-arm64)
    # macOS has no static libSystem: the goal here is "no non-system dylibs".
    MAKE_ARGS="OS=Darwin XLIBS=-lc++"
    STRIP="strip -x"
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    ;;
esac

# The makefiles look libraries up with pkg-config (libcrypto, X11, GL, curl,
# Tesseract, ...). Nothing must be found: the turned-off features stay off.
mkdir -p "$WORKDIR/mupdf-empty-pkgconfig"
export PKG_CONFIG_LIBDIR="$WORKDIR/mupdf-empty-pkgconfig"
export PKG_CONFIG_PATH="$WORKDIR/mupdf-empty-pkgconfig"

# ---------------------------------------------------------------------------
# MuPDF
# ---------------------------------------------------------------------------

if [ ! -d "$SOURCE" ]; then
  msg "fetching MuPDF $MUPDF_VERSION"
  download "https://mupdf.com/downloads/archive/mupdf-$MUPDF_VERSION-source.tar.gz" \
           "$SRCDIR/mupdf-$MUPDF_VERSION-source.tar.gz"
  ( cd "$SRCDIR" && tar -xzf "mupdf-$MUPDF_VERSION-source.tar.gz" )
fi
[ -f "$SOURCE/Makefile" ] || { echo "expected source directory $SOURCE not found" >&2; exit 1; }

# The version the sources declare, which `mutool -v` prints.
version_header="$SOURCE/include/mupdf/fitz/version.h"
source_version="$(sed -n 's/^#define FZ_VERSION "\(.*\)"$/\1/p' "$version_header")"
[ "$source_version" = "$MUPDF_VERSION" ] || {
  echo "the sources declare MuPDF '$source_version', expected '$MUPDF_VERSION'" >&2; exit 1;
}

msg "building mutool $MUPDF_VERSION for $TARGET"
# shellcheck disable=SC2086
make -C "$SOURCE" -j"$JOBS" build=release OUT="$OUT" $MAKE_ARGS \
  HAVE_X11=no HAVE_GLUT=no HAVE_CURL=no HAVE_LIBCRYPTO=no USE_TESSERACT=no \
  tools

# Depending on the toolchain, the linker adds .exe or not.
built=""
for candidate in "$OUT/mutool$EXE" "$OUT/mutool"; do
  if [ -f "$candidate" ]; then built="$candidate"; break; fi
done
[ -n "$built" ] || { echo "mutool was not built in $OUT" >&2; exit 1; }

out="$WORKDIR/mutool-$TARGET$EXE"
cp "$built" "$out"

msg "stripping"
$STRIP "$out"
chmod +x "$out"

ls -lh "$out"
msg "built mutool for $TARGET"
