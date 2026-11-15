#!/usr/bin/env bash
#
# Builds statically linked ktx, toktx and ktx2check, the tools of
# KTX-Software (https://github.com/KhronosGroup/KTX-Software), the reference
# implementation of KTX 2, from the release tag:
#
#   ktx-<target>[.exe], toktx-<target>[.exe], ktx2check-<target>[.exe]
#
#   bash scripts/build-ktx-software.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# The release has installers and dynamically linked tools. KTX-Software has
# its dependencies in its repository (Basis Universal, astc-encoder, zstd,
# lodepng, fmt, cxxopts): the tools are built with them, without the OpenGL
# and Vulkan upload code, and with the encoders built for no SIMD instruction
# set (BASISU_SUPPORT_SSE off, ASTCENC_ISA_NONE), so that every target writes
# the same bytes. The version of the tools comes from `git describe`: the tag
# is cloned with git.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# KTX_SOFTWARE_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

TOOL_ID=ktx-software
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"

require_versions KTX_SOFTWARE_VERSION
TOOLS="ktx toktx ktx2check"
# The CMake target of ktx is ktxtools: ktx is the library.
TARGETS="ktxtools toktx ktx2check"

SOURCE="$SRCDIR/KTX-Software-$KTX_SOFTWARE_VERSION"
if [ ! -d "$SOURCE/.git" ]; then
  msg "cloning KTX-Software v$KTX_SOFTWARE_VERSION"
  rm -rf "$SOURCE"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$KTX_SOFTWARE_VERSION" \
    https://github.com/KhronosGroup/KTX-Software.git "$SOURCE"
fi
described="$(git -C "$SOURCE" describe --match 'v[0-9]*' HEAD)"
[ "$described" = "v$KTX_SOFTWARE_VERSION" ] || { echo "git describe gives $described, not v$KTX_SOFTWARE_VERSION" >&2; exit 1; }

# astc-encoder archives its objects with CMAKE_CXX_COMPILER_AR, which CMake
# sets for clang from llvm-ar only: Alpine has no llvm-ar, the binutils ar does.
AR_ARGS=""
case "$TARGET" in
  linux-*) AR_ARGS="-DCMAKE_CXX_COMPILER_AR=$(command -v ar) -DCMAKE_CXX_COMPILER_RANLIB=$(command -v ranlib)" ;;
esac

# The fmt of the repository uses malloc and free without <cstdlib>, which the
# libc++ of llvm-mingw does not include from the other headers.
CXX_FLAGS_ARGS=""
LINK_FLAGS="$EXE_LDFLAGS"
if [ "$TARGET" = win-x64 ]; then
  CXX_FLAGS_ARGS="-DCMAKE_CXX_FLAGS=-include cstdlib"
  # ktx links -lPathcch, and MinGW has libpathcch.a: the Linux machine that
  # cross-compiles win-x64 has a case-sensitive file system.
  pathcch="$(find "$LLVM_MINGW_ROOT/$MINGW_TRIPLE/lib" -name libpathcch.a | sed -n 1p)"
  [ -n "$pathcch" ] || { echo "no libpathcch.a in $LLVM_MINGW_ROOT" >&2; exit 1; }
  mkdir -p "$WORKDIR/build-ktx-software-libs"
  cp "$pathcch" "$WORKDIR/build-ktx-software-libs/libPathcch.a"
  LINK_FLAGS="$LINK_FLAGS -L$WORKDIR/build-ktx-software-libs"
fi

BUILD="$WORKDIR/build-ktx-software"
msg "configuring KTX-Software $KTX_SOFTWARE_VERSION for $TARGET"
rm -rf "$BUILD"
# shellcheck disable=SC2086
cmake -S "$SOURCE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS_ARGS $AR_ARGS \
  -DBUILD_SHARED_LIBS=OFF -DKTX_FEATURE_TOOLS=ON -DKTX_FEATURE_TESTS=OFF -DKTX_FEATURE_TOOLS_CTS=OFF \
  -DKTX_FEATURE_DOC=OFF -DKTX_FEATURE_JNI=OFF -DKTX_FEATURE_PY=OFF -DKTX_FEATURE_LOADTEST_APPS=OFF \
  -DKTX_FEATURE_VK_UPLOAD=OFF -DKTX_FEATURE_GL_UPLOAD=OFF -DKTX_FEATURE_ETC_UNPACK=ON \
  -DBASISU_SUPPORT_SSE=OFF -DBASISU_SUPPORT_OPENCL=OFF -DASTCENC_ISA_NONE=ON \
  -DCMAKE_OSX_ARCHITECTURES=arm64 ${CXX_FLAGS_ARGS:+"$CXX_FLAGS_ARGS"} \
  "-DCMAKE_EXE_LINKER_FLAGS=$LINK_FLAGS"

msg "building $TOOLS"
# shellcheck disable=SC2086
cmake --build "$BUILD" --parallel "$JOBS" --target $TARGETS

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
