#!/usr/bin/env bash
#
# Builds statically linked Radiance picture tools -- pvalue, getinfo, pflip,
# protate, ra_xyze, ra_rgbe, ra_ppm and ra_bmp -- from the LBNL-ETA/Radiance
# sources.
#
#   bash scripts/build-radiance.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# Radiance releases are GitHub releases of commits of its master branch, tagged
# with the first 8 digits of the commit; the version, "6.1a", is the one of
# src/rt/VERSION and changes rarely. The release binaries need the whole
# Radiance installation (and a .pkg/.exe installer), so every target is built
# from the sources at RADIANCE_COMMIT. The build fails when src/rt/VERSION is
# not "RADIANCE $RADIANCE_VERSION", so that a new commit cannot be released
# under an older version.
#
# Only these tools and librtrad, the library they link, are built: no renderer,
# no X11 or OpenGL (BUILD_HEADLESS), no libtiff (no ra_tiff). Three changes to
# the CMake files of Radiance:
# - its `-mavx2 -mfma` for every non-Apple Unix build is removed: it would not
#   build for arm64, and needs an AVX2 machine for x64. With -ffp-contract=off,
#   ra_xyze and pvalue give the same values, bit for bit, on every target.
# - src/util requires OpenGL, even headless, for glrad, which is built with
#   X11 only: the lookup is made optional, and finds nothing.
# - the tools print no version, nor does any header they write: a source file
#   with "RADIANCE <version> (<release tag>)", which scripts/verify-radiance.sh
#   looks for, is linked into each one.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# RADIANCE_COMMIT and RADIANCE_VERSION come from the environment (see
# .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
for name in RADIANCE_COMMIT RADIANCE_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
SRCDIR="$WORKDIR/radiance-src"
SOURCE="$SRCDIR/Radiance-$RADIANCE_COMMIT"
BUILD="$WORKDIR/build-radiance-$TARGET"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS="pvalue getinfo pflip protate ra_xyze ra_rgbe ra_ppm ra_bmp"
RELEASE_TAG="$(printf '%s' "$RADIANCE_COMMIT" | cut -c1-8)"

mkdir -p "$SRCDIR"

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
CMAKE_CROSS_ARGS=""
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
    export MINGW_TRIPLE
    CMAKE_CROSS_ARGS="-DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/mingw-toolchain.cmake -DMINGW_TRIPLE=$MINGW_TRIPLE"
    # Links winpthreads statically.
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
# Sources
# ---------------------------------------------------------------------------

if [ ! -d "$SOURCE" ]; then
  msg "fetching Radiance $RADIANCE_COMMIT"
  download "https://github.com/LBNL-ETA/Radiance/archive/$RADIANCE_COMMIT.tar.gz" \
           "$SRCDIR/Radiance-$RADIANCE_COMMIT.tar.gz"
  ( cd "$SRCDIR" && tar -xzf "Radiance-$RADIANCE_COMMIT.tar.gz" )
fi
[ -f "$SOURCE/src/rt/VERSION" ] || { echo "expected source directory $SOURCE not found" >&2; exit 1; }

version_line="$(head -n 1 "$SOURCE/src/rt/VERSION" | tr -d '\r')"
[ "$version_line" = "RADIANCE $RADIANCE_VERSION" ] || {
  echo "src/rt/VERSION of $RADIANCE_COMMIT is '$version_line', and RADIANCE_VERSION is $RADIANCE_VERSION" >&2
  exit 1
}

# The CMake files are changed in a copy of the sources, so that a build always
# starts from the files of the release.
rm -rf "$BUILD"
mkdir -p "$BUILD"
cp -R "$SOURCE" "$BUILD/src"

top="$BUILD/src/CMakeLists.txt"
grep -q '^    add_compile_options(-mavx2 -mfma)$' "$top" \
  || { echo "the -mavx2 -mfma line of $top changed: check what Radiance compiles with" >&2; exit 1; }
sed -e '/^    add_compile_options(-mavx2 -mfma)$/d' "$top" > "$top.new"
mv "$top.new" "$top"

util="$BUILD/src/src/util/CMakeLists.txt"
grep -q '^  find_package(OpenGL REQUIRED)$' "$util" \
  || { echo "the OpenGL lookup of $util changed: check what it needs" >&2; exit 1; }
sed -e 's/^  find_package(OpenGL REQUIRED)$/  find_package(OpenGL)/' "$util" > "$util.new"
mv "$util.new" "$util"

cat > "$BUILD/src/prebuilt-version.c" <<EOF
/* Linked into each tool by scripts/build-radiance.sh: they print no version. */
__attribute__((used)) const char prebuilt_radiance_version[] = "RADIANCE $RADIANCE_VERSION ($RELEASE_TAG)";
EOF
{
  echo ""
  echo "# scripts/build-radiance.sh"
  echo "foreach(tool $TOOLS)"
  echo "  target_sources(\${tool} PRIVATE \"\${CMAKE_SOURCE_DIR}/prebuilt-version.c\")"
  echo "endforeach()"
} >> "$top"

# Radiance is built with MSVC on Windows, which accepts calls to undeclared
# functions: fropen.c calls isupper and islower without <ctype.h>, getpath.c
# and gethomedir.c call strlcpy and strlcat (strlcpy.c) without rtio.h. Clang
# rejects these calls, so every file sees their declarations first.
FORCED_INCLUDE=""
if [ "$TARGET" = "win-x64" ]; then
  cat > "$BUILD/src/prebuilt-mingw.h" <<'EOF'
/* Included first in every file by scripts/build-radiance.sh. */
#include <ctype.h>
#include <stddef.h>
extern size_t strlcpy(char *dst, const char *src, size_t siz);
extern size_t strlcat(char *dst, const char *src, size_t siz);
EOF
  FORCED_INCLUDE=" -include $BUILD/src/prebuilt-mingw.h"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

msg "configuring Radiance $RADIANCE_VERSION ($RELEASE_TAG) for $TARGET"
# The source copy is not a git repository: the commit CMake would ask git for
# is not needed. No package must be found on the machine: TIFF (ra_tiff, not
# built), X11 and OpenGL (BUILD_HEADLESS), Qt (BUILD_QT is off).
# shellcheck disable=SC2086
cmake -S "$BUILD/src" -B "$BUILD/cmake" -G Ninja $CMAKE_CROSS_ARGS \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_HEADLESS=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_Git=ON -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_X11=ON -DCMAKE_DISABLE_FIND_PACKAGE_OpenGL=ON \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_C_FLAGS="-ffp-contract=off$FORCED_INCLUDE" -DCMAKE_CXX_FLAGS="-ffp-contract=off" \
  -DCMAKE_EXE_LINKER_FLAGS="$EXE_LDFLAGS"

msg "building $TOOLS"
# shellcheck disable=SC2086
cmake --build "$BUILD/cmake" --parallel "$JOBS" --target $TOOLS

OUTPUTS=""
for tool in $TOOLS; do
  out="$WORKDIR/$tool-$TARGET$EXE"
  cp "$BUILD/cmake/bin/$tool$EXE" "$out"
  OUTPUTS="$OUTPUTS $out"
done

msg "stripping"
# shellcheck disable=SC2086
$STRIP $OUTPUTS
# shellcheck disable=SC2086
chmod +x $OUTPUTS

# shellcheck disable=SC2086
ls -lh $OUTPUTS
msg "built $TOOLS for $TARGET"
