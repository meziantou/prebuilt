#!/usr/bin/env bash
#
# Builds a statically linked jpeg, the command-line tool of the ISO JPEG
# reference codec (thorfdbg/libjpeg), and names it iso-jpeg: jpeg says too
# little for a file of a release.
#
#   bash scripts/build-iso-jpeg.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# libjpeg has no release tag and publishes no binaries, so every target is
# built from a commit of its master branch. The tool prints no version:
# ISO_JPEG_VERSION is the last release README.history describes at that commit,
# and the build fails when it is not, so that a new commit cannot be released
# under the number of an older release.
#
# The makefiles of libjpeg are used as they are, with their `final` target:
# the default one is a debug build, without optimization and with the internal
# checks. libjpeg has no dependency.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# ISO_JPEG_COMMIT and ISO_JPEG_VERSION come from the environment (see
# .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
for name in ISO_JPEG_COMMIT ISO_JPEG_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
SRCDIR="$WORKDIR/iso-jpeg-src"
SOURCE="$SRCDIR/libjpeg-$ISO_JPEG_COMMIT"
BUILD="$WORKDIR/build-iso-jpeg"

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
    # Links libc++, libunwind and winpthreads statically.
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

# ---------------------------------------------------------------------------
# libjpeg
# ---------------------------------------------------------------------------

if [ ! -d "$SOURCE" ]; then
  msg "fetching libjpeg $ISO_JPEG_COMMIT"
  download "https://github.com/thorfdbg/libjpeg/archive/$ISO_JPEG_COMMIT.tar.gz" \
           "$SRCDIR/libjpeg-$ISO_JPEG_COMMIT.tar.gz"
  ( cd "$SRCDIR" && tar -xzf "libjpeg-$ISO_JPEG_COMMIT.tar.gz" )
fi
[ -f "$SOURCE/README.history" ] || { echo "expected source directory $SOURCE not found" >&2; exit 1; }

# README.history ends with the release the commit belongs to ("Release 1.72:").
release="$(sed -n 's/^Release \([0-9][0-9.]*\):.*$/\1/p' "$SOURCE/README.history" | tail -n 1)"
[ "$release" = "$ISO_JPEG_VERSION" ] || {
  echo "README.history of $ISO_JPEG_COMMIT ends with release '$release', and ISO_JPEG_VERSION is $ISO_JPEG_VERSION" >&2
  exit 1
}

# The makefiles build in the source directory: every build starts from a copy
# of the sources, so that the objects of another target are never linked.
rm -rf "$BUILD"
cp -R "$SOURCE" "$BUILD"
cd "$BUILD"

# configure and autoconfig.h.in are generated from configure.in, and the
# repository holds them. The makefiles run autoconf and autoheader again when
# configure.in is the newer file, which it can be in a copy.
touch configure autoconfig.h.in

msg "configuring libjpeg $ISO_JPEG_VERSION ($ISO_JPEG_COMMIT) for $TARGET"
case "$TARGET" in
  win-x64)
    # configure cannot cross-compile: it runs a test program to measure the
    # alignment of the types. What it does is done here instead:
    # - automakefile holds the variables the makefiles take from it. SETTINGS
    #   selects Makefile_Settings.clang, as configure does from $CC everywhere
    #   else.
    # - the sources include autoconfig.h when USE_AUTOCONF is defined. Without
    #   it, config.h has a configuration for Windows, which the WIN32 and WIN64
    #   macros select: it is the one the Visual Studio projects of libjpeg
    #   build with, and the mingw compilers define both macros.
    # - autoconfig.h has to exist, and to be newer than configure: the `final`
    #   target depends on it and runs configure otherwise.
    cat > automakefile <<EOF
COMPILER_CMD	=	$MINGW_TRIPLE-clang++
CC_ONLY		=	$MINGW_TRIPLE-clang
SETTINGS	=	clang
EOF
    : > autoconfig.h
    # mingw-w64 has no libc.a for the -lc of the makefiles.
    LINK_LIBS="-lm"
    ;;
  *)
    ./configure
    LINK_LIBS="-lc -lm"
    ;;
esac

# `final` compiles with the OPTIMIZER flags of Makefile_Settings.clang: -O3
# -ffast-math, without the debug and the check code. LDFLAGS and LDLIBS are
# the variables of the link command.
msg "building jpeg"
make -j "$JOBS" final LDFLAGS="$EXE_LDFLAGS" LDLIBS="$LINK_LIBS"

# The link command asks for `jpeg` on every platform: the mingw linker adds
# the extension.
built="$BUILD/jpeg$EXE"
[ -f "$built" ] || { echo "$built was not built" >&2; exit 1; }

cd "$WORKDIR"
OUTPUT="$WORKDIR/iso-jpeg-$TARGET$EXE"
cp "$built" "$OUTPUT"

msg "stripping"
$STRIP "$OUTPUT"
chmod +x "$OUTPUT"

ls -lh "$OUTPUT"
msg "built iso-jpeg for $TARGET"
