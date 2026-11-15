#!/usr/bin/env bash
#
# Builds a statically linked dng_validate, the command-line tool of the Adobe
# DNG SDK, the reference implementation of DNG: it validates DNG files, and
# renders them (the stages of the raw processing, and a TIFF image) or writes
# them again as DNG (with JPEG XL compression):
#
#   dng_validate-<target>[.exe]
#
#   bash scripts/build-dng-sdk.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# The SDK is the zip file Adobe publishes, checked against DNG_SDK_SHA256. It
# has Xcode and Visual Studio projects only: scripts/dng-sdk-CMakeLists.txt is
# its CMake build (libjpeg, XMPCore and libjxl from the SDK, then
# dng_validate), with expat (EXPAT_VERSION, the XML parser of XMPCore, which
# the SDK does not have) and zlib (the version the other tools are built
# with, scripts/pdf-libs.sh).
#
# The DNG SDK is available under the Adobe DNG SDK License Agreement, which
# allows its use, modification and distribution in source and binary form,
# keeping its copyright notices.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# DNG_SDK_VERSION, DNG_SDK_SHA256, EXPAT_VERSION and ZLIB_VERSION come from the
# environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

TOOL_ID=dng-sdk
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"
. "$SCRIPT_DIR/pdf-libs.sh"

require_versions DNG_SDK_VERSION DNG_SDK_SHA256 EXPAT_VERSION

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

build_zlib

# 1.7.1 is dng_sdk_1_7_1.zip, with a dng_sdk_1_7_1 folder.
SDK_NAME="dng_sdk_$(echo "$DNG_SDK_VERSION" | tr . _)"
SOURCE="$SRCDIR/$SDK_NAME"
if [ ! -d "$SOURCE" ]; then
  msg "fetching the DNG SDK $DNG_SDK_VERSION"
  download "https://download.adobe.com/pub/adobe/dng/$SDK_NAME.zip" "$SRCDIR/$SDK_NAME.zip"
  actual="$(sha256_of "$SRCDIR/$SDK_NAME.zip")"
  [ "$actual" = "$DNG_SDK_SHA256" ] || { echo "the SHA-256 of $SDK_NAME.zip is $actual, expected $DNG_SDK_SHA256" >&2; exit 1; }
  ( cd "$SRCDIR" && unzip -q "$SDK_NAME.zip" )
fi
[ -f "$SOURCE/dng_sdk/source/dng_validate.cpp" ] || { echo "no dng_sdk/source/dng_validate.cpp in $SOURCE" >&2; exit 1; }
grep -q "^#define kDNGValidateVersion \"$DNG_SDK_VERSION\"" "$SOURCE/dng_sdk/source/dng_validate.cpp" \
  || { echo "dng_validate.cpp is not version $DNG_SDK_VERSION" >&2; exit 1; }

fetch expat "https://github.com/libexpat/libexpat/releases/download/R_$(echo "$EXPAT_VERSION" | tr . _)/expat-$EXPAT_VERSION.tar.xz" \
      "expat-$EXPAT_VERSION.tar.xz" "expat-$EXPAT_VERSION"

cp "$SCRIPT_DIR/dng-sdk-CMakeLists.txt" "$SOURCE/CMakeLists.txt"

# The XMP Toolkit takes a MinGW build for an old MSVC (_MSC_VER <= 1600, with
# no _MSC_VER), and its shared pointers from std::tr1.
defines="$SOURCE/xmp/toolkit/public/include/XMPCommon/XMPCommonDefines.h"
sed 's/^\(\t*\)#if _MSC_VER <= 1600$/\1#if defined(_MSC_VER) \&\& _MSC_VER <= 1600/' "$defines" > "$defines.tmp" && mv "$defines.tmp" "$defines"
grep -q '#if defined(_MSC_VER) && _MSC_VER <= 1600' "$defines" || { echo "XMPCommonDefines.h was not patched" >&2; exit 1; }

# On Windows, the SDK emulates pthreads, for MSVC: a MinGW build uses the
# pthreads of MinGW (winpthreads) instead, as the other platforms do theirs,
# with a recursive mutex (dng_mutex.cpp).
for file in dng_pthread.h dng_pthread.cpp dng_mutex.cpp; do
  path="$SOURCE/dng_sdk/source/$file"
  sed -e 's/^\([[:space:]]*\)#if !qWinOS$/\1#if !qWinOS || defined(__MINGW32__)/' \
      -e 's/^\([[:space:]]*\)#if qWinOS$/\1#if qWinOS \&\& !defined(__MINGW32__)/' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
  grep -q '__MINGW32__' "$path" || { echo "$file was not patched" >&2; exit 1; }
done

# The XMP Toolkit uses SAL annotations of MSVC (_Check_return_wat_, ...) that
# MinGW does not define: SuppressSAL.h defines them as empty for MinGW too, as
# it does for the other platforms.
sal="$SOURCE/xmp/toolkit/source/SuppressSAL.h"
sed 's|^#if !defined(_WIN32) && !defined(_WIN64) /\*|#if (!defined(_WIN32) \&\& !defined(_WIN64)) \|\| defined(__MINGW32__) /*|' "$sal" > "$sal.tmp" && mv "$sal.tmp" "$sal"
grep -q 'defined(__MINGW32__)' "$sal" || { echo "SuppressSAL.h was not patched" >&2; exit 1; }

# The sources include Windows headers in mixed case (<Windows.h>, ...), and
# the MinGW headers are lowercase: forwarding headers, for the case-sensitive
# file system of the Linux machine that cross-compiles win-x64.
SHIMS_ARG=""
if [ "$TARGET" = win-x64 ]; then
  mingw_include="$LLVM_MINGW_ROOT/$MINGW_TRIPLE/include"
  [ -f "$mingw_include/windows.h" ] || { echo "no windows.h in $mingw_include" >&2; exit 1; }
  shims="$WORKDIR/build-dng-sdk-case"
  rm -rf "$shims"
  mkdir -p "$shims"
  find "$SOURCE/dng_sdk" "$SOURCE/xmp" -name '*.h' -o -name '*.hpp' -o -name '*.cpp' -o -name '*.incl_cpp' \
    | xargs sed -n 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*<\([^>]*\)>.*/\1/p' | sort -u \
    | while read -r header; do
        target="$(echo "$header" | tr 'A-Z\\' 'a-z/')"
        [ "$header" != "$target" ] || continue
        if [ ! -f "$mingw_include/$header" ] && [ -f "$mingw_include/$target" ]; then
          printf '#include <%s>\n' "$target" > "$shims/$header"
        fi
      done
  echo "forwarding headers: $(ls "$shims" | tr '\n' ' ')"
  SHIMS_ARG="-DDNG_INCLUDE_SHIMS=$shims"
fi

BUILD="$WORKDIR/build-dng-sdk"
msg "configuring the DNG SDK $DNG_SDK_VERSION for $TARGET"
rm -rf "$BUILD"
# CMAKE_POLICY_VERSION_MINIMUM: the libjxl of the SDK and its third-party
# libraries ask for an older CMake than CMake 4 accepts.
# shellcheck disable=SC2086
cmake -S "$SOURCE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS_ARGS \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
  -DEXPAT_SOURCE_DIR="$SRCDIR/expat-$EXPAT_VERSION" -DZLIB_ROOT="$PREFIX" ${SHIMS_ARG:+"$SHIMS_ARG"} \
  "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"

msg "building dng_validate"
cmake --build "$BUILD" --parallel "$JOBS" --target dng_validate

out="$WORKDIR/dng_validate-$TARGET$EXE"
cp "$BUILD/dng_validate$EXE" "$out"
finish_outputs "$out"
msg "built dng_validate for $TARGET"
