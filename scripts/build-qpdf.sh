#!/usr/bin/env bash
#
# Builds a statically linked qpdf, the PDF structure tool of the qpdf project.
#
#   bash scripts/build-qpdf.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# Every target is built from the sources of the release: the release has no
# Linux musl binaries, and its other binaries link libqpdf and the crypto
# libraries dynamically.
#
# qpdf is built with its native crypto provider only, without OpenSSL or
# GnuTLS: it implements RC4, AES-128 and AES-256 (and the MD5, SHA-2 hashes
# they need) itself, so every encryption variant of the PDF specification is
# available. zlib and libjpeg-turbo come from scripts/pdf-deps.sh.
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

TOOL_ID=qpdf
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"

require_versions QPDF_VERSION ZLIB_VERSION LIBJPEG_TURBO_VERSION

build_zlib
build_libjpeg_turbo

# ---------------------------------------------------------------------------
# qpdf
# ---------------------------------------------------------------------------

fetch qpdf "https://github.com/qpdf/qpdf/releases/download/v$QPDF_VERSION/qpdf-$QPDF_VERSION.tar.gz" \
      "qpdf-$QPDF_VERSION.tar.gz" "qpdf-$QPDF_VERSION"

# Targeting MinGW, qpdf links CRT_glob.o (wildcard expansion of the command
# line, as setargv.obj does with MSVC), and asks `gcc` where it is: the gcc of
# the build machine, when cross-compiling, which answers with the bare name.
# The compiler of the build is asked instead.
QPDF_CMAKELISTS="$SRCDIR/qpdf-$QPDF_VERSION/CMakeLists.txt"
if grep -F 'COMMAND gcc --print-file-name=CRT_glob.o' "$QPDF_CMAKELISTS" >/dev/null; then
  sed 's|COMMAND gcc --print-file-name=CRT_glob.o|COMMAND ${CMAKE_CXX_COMPILER} --print-file-name=CRT_glob.o|' \
    "$QPDF_CMAKELISTS" > "$QPDF_CMAKELISTS.patched"
  mv "$QPDF_CMAKELISTS.patched" "$QPDF_CMAKELISTS"
fi
grep -F 'COMMAND ${CMAKE_CXX_COMPILER} --print-file-name=CRT_glob.o' "$QPDF_CMAKELISTS" >/dev/null \
  || { echo "the CRT_glob.o lookup of $QPDF_CMAKELISTS was not patched" >&2; exit 1; }

# USE_IMPLICIT_CRYPTO=OFF with REQUIRE_CRYPTO_NATIVE=ON: no external crypto
# library is looked up, and the configuration fails rather than silently use
# one. STATIC_JPEG links the libjpeg.a of the prefix.
QPDF_BUILD="$WORKDIR/build-qpdf-qpdf"
msg "configuring qpdf $QPDF_VERSION for $TARGET"
# shellcheck disable=SC2086
cmake -S "$SRCDIR/qpdf-$QPDF_VERSION" -B "$QPDF_BUILD" $CMAKE_COMMON $CMAKE_CROSS_ARGS \
  -DBUILD_STATIC_LIBS=ON -DBUILD_DOC=OFF -DINSTALL_MANUAL=OFF -DINSTALL_EXAMPLES=OFF \
  -DUSE_IMPLICIT_CRYPTO=OFF -DREQUIRE_CRYPTO_NATIVE=ON \
  -DSTATIC_JPEG=ON -DLIBJPEG_STATIC_PATH="$PREFIX/lib/libjpeg.a" \
  -DCMAKE_EXE_LINKER_FLAGS="$EXE_LDFLAGS"

# The crypto providers the configuration selected are written to this header.
qpdf_config="$QPDF_BUILD/libqpdf/qpdf/qpdf-config.h"
[ -f "$qpdf_config" ] || { echo "$qpdf_config was not generated" >&2; exit 1; }
grep -E '^#define USE_CRYPTO_NATIVE' "$qpdf_config" >/dev/null || { echo "qpdf is not configured with native crypto" >&2; exit 1; }
if grep -E '^#define USE_CRYPTO_(OPENSSL|GNUTLS)' "$qpdf_config"; then
  echo "qpdf is configured with an external crypto library" >&2; exit 1
fi

msg "building qpdf"
cmake --build "$QPDF_BUILD" --parallel "$JOBS" --target qpdf

built="$QPDF_BUILD/qpdf/qpdf$EXE"
[ -f "$built" ] || { echo "qpdf$EXE was not built in $QPDF_BUILD/qpdf" >&2; exit 1; }
out="$WORKDIR/qpdf-$TARGET$EXE"
cp "$built" "$out"

finish_outputs "$out"
msg "built qpdf for $TARGET"
