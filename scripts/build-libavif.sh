#!/usr/bin/env bash
#
# Builds statically linked avifenc/avifdec from the libavif sources.
#
#   bash scripts/build-libavif.sh <target>
#
# Targets: linux-x64 | linux-arm64
#
# Only the targets the libavif release has no usable binary for are built here:
# it has no Linux arm64 build, and its Linux x64 build links glibc and
# libstdc++ dynamically. The Windows x64 and macOS arm64 binaries of the release
# are repackaged as is (see the libavif job in .github/workflows/ci.yml).
#
# The configuration is the one of libavif's own release workflows
# (.github/workflows/ci-*-artifacts.yml in its repository), so every runtime
# identifier gets the same codecs: libaom to encode, dav1d to decode. For the
# same reason the codecs and the other dependencies (libyuv, libsharpyuv, zlib,
# libpng, libjpeg-turbo) are the versions the libavif release pins itself in
# cmake/Modules/Local*.cmake, not the ones ffmpeg is built with.
#
# LIBAVIF_VERSION comes from the environment (see .github/workflows/ci.yml).

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64>" >&2; exit 2 ;;
esac
[ -n "$LIBAVIF_VERSION" ] || { echo "LIBAVIF_VERSION is not set" >&2; exit 2; }

WORKDIR="$(pwd)"
SRCDIR="$WORKDIR/libavif-src"
SOURCE="$SRCDIR/libavif-$LIBAVIF_VERSION"
BUILD="$WORKDIR/build-libavif"

msg() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# The dependencies are cloned by CMake, at configure time (FetchContent) and at
# build time (ExternalProject), from hosts that fail every now and then. Both
# steps pick up where they stopped, so running them again is cheap.
retry() {
  attempt=1
  while ! "$@"; do
    if [ "$attempt" -ge 3 ]; then
      echo "failed after $attempt attempts: $*" >&2
      return 1
    fi
    echo "attempt $attempt failed: $*" >&2
    attempt=$((attempt + 1))
    sleep $((5 * attempt))
  done
}

if [ ! -d "$SOURCE" ]; then
  msg "fetching libavif $LIBAVIF_VERSION"
  mkdir -p "$SRCDIR"
  archive="$SRCDIR/libavif-$LIBAVIF_VERSION.tar.gz"
  retry curl -fsSL --retry 2 --connect-timeout 30 \
    "https://github.com/AOMediaCodec/libavif/archive/refs/tags/v$LIBAVIF_VERSION.tar.gz" -o "$archive"
  tar -xzf "$archive" -C "$SRCDIR"
fi
[ -f "$SOURCE/CMakeLists.txt" ] || { echo "expected source directory $SOURCE not found" >&2; exit 1; }

# Same compiler as the ffmpeg build and as libavif's release workflow.
export CC=clang CXX=clang++

msg "configuring libavif $LIBAVIF_VERSION for $TARGET"
# musl's default thread stack is 128 KB; libaom overflows it.
retry cmake -G Ninja -S "$SOURCE" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DAVIF_CODEC_AOM=LOCAL -DAVIF_CODEC_AOM_ENCODE=ON -DAVIF_CODEC_AOM_DECODE=OFF \
  -DAVIF_CODEC_DAV1D=LOCAL \
  -DAVIF_LIBSHARPYUV=LOCAL -DAVIF_LIBYUV=LOCAL -DAVIF_ZLIBPNG=LOCAL -DAVIF_JPEG=LOCAL \
  -DAVIF_BUILD_EXAMPLES=OFF -DAVIF_BUILD_APPS=ON -DAVIF_BUILD_TESTS=OFF \
  -DCMAKE_EXE_LINKER_FLAGS="-static -Wl,-z,stack-size=2097152"

msg "building avifenc and avifdec"
retry cmake --build "$BUILD" --target avifenc avifdec

AVIFENC_OUT="$WORKDIR/avifenc-$TARGET"
AVIFDEC_OUT="$WORKDIR/avifdec-$TARGET"
cp "$BUILD/avifenc" "$AVIFENC_OUT"
cp "$BUILD/avifdec" "$AVIFDEC_OUT"

msg "stripping"
strip "$AVIFENC_OUT" "$AVIFDEC_OUT"
chmod +x "$AVIFENC_OUT" "$AVIFDEC_OUT"

ls -lh "$AVIFENC_OUT" "$AVIFDEC_OUT"
msg "built $(basename "$AVIFENC_OUT") and $(basename "$AVIFDEC_OUT")"
