#!/usr/bin/env bash
#
# Builds a statically linked unrar, the freeware RAR extractor of RARLAB, from
# its official sources (unrarsrc-<version>.tar.gz).
#
#   bash scripts/build-unrar.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# RARLAB publishes a Windows unrar only, as an installer. Every target is built
# from the source tarball with its own makefile. rar, the archiver, is
# proprietary and not built: the sources are the extractor only.
#
# UNRAR_SOURCE_VERSION is the version of the tarball (7.2.7), and UNRAR_VERSION
# the version unrar prints (7.23): RARLAB numbers its tarballs with a counter
# of its own. This script fails when version.hpp of the tarball is not
# UNRAR_VERSION or is a beta. RARLAB publishes no checksum of the tarballs:
# UNRAR_SHA256 pins the content.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. The makefile targets Unix only; the Windows build
# gets the changes the MinGW package of MSYS2 makes (mingw-w64-unrar): the
# objects of the Windows-only sources, the import libraries the sources ask
# MSVC for with #pragma comment, the lower-case names of the Windows headers,
# and the x64 checks of the MSVC macros extended to the GCC/clang ones.
# Every other target builds natively.
#
# The Windows build changes the UnRAR sources, which the unRAR license
# (license.txt of the tarball) allows on this condition:
#
#   UnRAR source code may be used in any software to handle RAR archives
#   without limitations free of charge, but cannot be used to develop RAR
#   (WinRAR) compatible archiver and to re-create RAR compression algorithm,
#   which is proprietary. Distribution of modified UnRAR source code in
#   separate form or as a part of other software is permitted, provided that
#   full text of this paragraph, starting from "UnRAR source code" words, is
#   included in license, or in documentation if license is not available, and
#   in source code comments of resulting package.
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
for name in UNRAR_VERSION UNRAR_SOURCE_VERSION UNRAR_SHA256; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
SRCDIR="$WORKDIR/unrar-src"

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

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# Download with retries; keep the file only when it has the pinned content.
download() {
  url="$1"; out="$2"; expected="$3"
  attempt=1
  while [ "$attempt" -le 5 ]; do
    rm -f "$out"
    if curl -fsSL --retry 2 --connect-timeout 30 "$url" -o "$out"; then
      actual="$(sha256_of "$out")"
      [ "$actual" = "$expected" ] && return 0
      echo "$url has SHA-256 $actual, expected $expected" >&2
    fi
    echo "download attempt $attempt failed: $url" >&2
    attempt=$((attempt + 1))
    sleep $((2 * attempt))
  done
  rm -f "$out"
  echo "failed to download $url with SHA-256 $expected" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

msg "fetching unrarsrc $UNRAR_SOURCE_VERSION"
rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
download "https://www.rarlab.com/rar/unrarsrc-$UNRAR_SOURCE_VERSION.tar.gz" \
  "$SRCDIR/unrarsrc-$UNRAR_SOURCE_VERSION.tar.gz" "$UNRAR_SHA256"
( cd "$SRCDIR" && tar -xzf "unrarsrc-$UNRAR_SOURCE_VERSION.tar.gz" )
SOURCE="$SRCDIR/unrar"
[ -f "$SOURCE/makefile" ] || { echo "no unrar/makefile in unrarsrc-$UNRAR_SOURCE_VERSION.tar.gz" >&2; exit 1; }

# unrar prints RARVER_MAJOR.RARVER_MINOR, with two digits for the minor
# version ("7.23"), and "beta <n>" after it when RARVER_BETA is not 0.
version_define() {
  sed -n "s/^#define $1[[:space:]]*\([0-9]*\).*/\1/p" "$SOURCE/version.hpp"
}
major="$(version_define RARVER_MAJOR)"
minor="$(version_define RARVER_MINOR)"
beta="$(version_define RARVER_BETA)"
[ -n "$major" ] && [ -n "$minor" ] && [ -n "$beta" ] || { echo "could not read the version of version.hpp" >&2; exit 1; }
source_version="$(printf '%d.%02d' "$major" "$minor")"
[ "$source_version" = "$UNRAR_VERSION" ] || {
  echo "unrarsrc-$UNRAR_SOURCE_VERSION is unrar $source_version, and UNRAR_VERSION is $UNRAR_VERSION" >&2
  exit 1
}
[ "$beta" = "0" ] || { echo "unrarsrc-$UNRAR_SOURCE_VERSION is unrar $source_version beta $beta" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Target configuration
# ---------------------------------------------------------------------------

EXE=""
STRIP="strip"
# The DEFINES of the makefile.
DEFINES="-D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -DRAR_SMP"
EXTRA_OBJ=""
LIBS=""

case "$TARGET" in
  linux-*)
    # Same compiler as the other builds.
    CXX=clang++
    LDFLAGS="-static -pthread"
    ;;
  win-x64)
    EXE=".exe"
    [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
    export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
    CXX=x86_64-w64-mingw32-clang++
    STRIP=x86_64-w64-mingw32-strip
    # Links libc++, libunwind and winpthreads statically.
    LDFLAGS="-static"
    # os.hpp defines RAR_SMP itself on Windows.
    DEFINES="-D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE"
    # The Windows-only sources the makefile does not list.
    EXTRA_OBJ="isnt.o motw.o"
    # The libraries of the #pragma comment(lib, ...) lines removed below, and
    # the ones the Windows code of the sources calls into.
    LIBS="-lshlwapi -lpowrprof -lpsapi -lwbemuuid -lole32 -loleaut32 -lbcrypt -luuid"

    msg "adapting the Windows sources to MinGW"
    # The Windows SDK headers are found whatever the case of their names; the
    # MinGW ones have lower-case names, on a case-sensitive file system. GNU
    # sed: the Windows build is cross-compiled on Linux only.
    for file in "$SOURCE"/*.cpp "$SOURCE"/*.hpp; do
      sed -i -e 's/^\([[:space:]]*#include[[:space:]]*<\)\([^>]*[A-Z][^>]*\)>/\1\L\2\E>/' "$file"
    done
    sed -i \
      -e '/#pragma comment(lib/d' \
      -e 's/defined(_M_IX86) || defined(_M_X64)/defined(_M_IX86) || defined(_M_X64) || defined(__i386__) || defined(__x86_64__)/' \
      "$SOURCE/os.hpp"
    sed -i -e 's/^\([[:space:]]*\)#ifdef _M_X64$/\1#if defined(_M_X64) || defined(__x86_64__)/' "$SOURCE/raros.hpp"
    # Each change must have been made: a new unrarsrc can move these lines.
    ! grep -q '#pragma comment(lib' "$SOURCE/os.hpp" || { echo "os.hpp still has #pragma comment(lib" >&2; exit 1; }
    ! grep -n '^[[:space:]]*#include[[:space:]]*<[^>]*[A-Z]' "$SOURCE"/*.cpp "$SOURCE"/*.hpp || { echo "mixed-case includes are left" >&2; exit 1; }
    grep -q 'defined(__x86_64__)' "$SOURCE/os.hpp" || { echo "os.hpp no longer checks _M_X64 for SSE" >&2; exit 1; }
    grep -q 'defined(__x86_64__)' "$SOURCE/raros.hpp" || { echo "raros.hpp no longer checks _M_X64" >&2; exit 1; }
    ;;
  osx-arm64)
    # macOS has no static libSystem: the goal here is "no non-system dylibs".
    CXX=c++
    LDFLAGS="-pthread"
    STRIP="strip -x"
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    ;;
esac

# ---------------------------------------------------------------------------
# unrar
# ---------------------------------------------------------------------------

msg "building unrar $UNRAR_VERSION ($UNRAR_SOURCE_VERSION) for $TARGET"
# UNRAR_OBJ, DEFINES, LIBS and LDFLAGS are variables of the makefile; the
# makefile strips the binary with STRIP, which is done below instead.
make -C "$SOURCE" -f makefile -j "$JOBS" unrar \
  CXX="$CXX" STRIP=true \
  DEFINES="$DEFINES" \
  UNRAR_OBJ="filestr.o recvol.o rs.o scantree.o qopen.o $EXTRA_OBJ" \
  LDFLAGS="$LDFLAGS" LIBS="$LIBS"

out="$WORKDIR/unrar-$TARGET$EXE"
# The makefile links "-o unrar", which a toolchain targeting Windows may name
# unrar.exe.
built="$SOURCE/unrar"
[ -f "$built" ] || built="$SOURCE/unrar$EXE"
[ -f "$built" ] || { echo "the build wrote no unrar binary" >&2; exit 1; }
cp "$built" "$out"

msg "stripping"
$STRIP "$out"
chmod +x "$out"

ls -lh "$out"
msg "built unrar for $TARGET"
