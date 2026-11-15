#!/usr/bin/env bash
#
# Builds statically linked texconv, texdiag and texassemble, the tools of
# DirectXTex (https://github.com/microsoft/DirectXTex), from the release tag:
#
#   texconv-win-x64.exe, texdiag-win-x64.exe, texassemble-win-x64.exe
#
#   bash scripts/build-directxtex.sh win-x64
#
# Targets: win-x64 only. The tools read and write images with WIC (the
# Windows Imaging Component): the DirectXTex library builds on Linux and
# macOS, its tools do not.
#
# The release has the tools, linked with the Visual C++ runtime, which Windows
# does not have unless the Visual C++ Redistributable is installed. They are
# cross-compiled here with llvm-mingw, statically, without OpenMP, with
# DirectXMath and DirectX-Headers (the headers MinGW builds use).
#
# The GPU encoders of BC6H and BC7 are compute shaders compiled with fxc.exe,
# a tool of the Windows SDK only: the build uses empty shaders, and texconv is
# patched to never create a Direct3D 11 device, so that it always uses the CPU
# encoders (as with -nogpu). GPU encoders give results that depend on the
# graphics card; the CPU encoders give the same bytes on every machine.
#
# Point LLVM_MINGW_ROOT at the extracted toolchain.
#
# DIRECTXTEX_VERSION, DIRECTXTEX_LIBRARY_VERSION, DIRECTXMATH_VERSION and
# DIRECTX_HEADERS_VERSION come from the environment (see
# .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  win-x64) ;;
  *) echo "usage: $0 win-x64 (the DirectXTex tools are Windows tools)" >&2; exit 2 ;;
esac

TOOL_ID=directxtex
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"

require_versions DIRECTXTEX_VERSION DIRECTXTEX_LIBRARY_VERSION DIRECTXMATH_VERSION DIRECTX_HEADERS_VERSION
TOOLS="texconv texdiag texassemble"

# ---------------------------------------------------------------------------
# DirectXMath and DirectX-Headers: CMake packages of headers.
# ---------------------------------------------------------------------------

if ! stamp_done "directxmath-$DIRECTXMATH_VERSION"; then
  fetch DirectXMath "https://github.com/microsoft/DirectXMath/archive/refs/tags/$DIRECTXMATH_VERSION.tar.gz" \
        "DirectXMath-$DIRECTXMATH_VERSION.tar.gz" "DirectXMath-$DIRECTXMATH_VERSION"
  run_cmake directxmath "$SRCDIR/DirectXMath-$DIRECTXMATH_VERSION" -DBUILD_TESTING=OFF -DBUILD_XDSP=OFF -DBUILD_SHMATH=OFF
  stamp_mark "directxmath-$DIRECTXMATH_VERSION"
fi
if ! stamp_done "directx-headers-$DIRECTX_HEADERS_VERSION"; then
  fetch DirectX-Headers "https://github.com/microsoft/DirectX-Headers/archive/refs/tags/v$DIRECTX_HEADERS_VERSION.tar.gz" \
        "DirectX-Headers-$DIRECTX_HEADERS_VERSION.tar.gz" "DirectX-Headers-$DIRECTX_HEADERS_VERSION"
  run_cmake directx-headers "$SRCDIR/DirectX-Headers-$DIRECTX_HEADERS_VERSION" -DDXHEADERS_BUILD_TEST=OFF -DDXHEADERS_BUILD_GOOGLE_TEST=OFF
  stamp_mark "directx-headers-$DIRECTX_HEADERS_VERSION"
fi

# ---------------------------------------------------------------------------
# DirectXTex
# ---------------------------------------------------------------------------

fetch DirectXTex "https://github.com/microsoft/DirectXTex/archive/refs/tags/$DIRECTXTEX_VERSION.tar.gz" \
      "DirectXTex-$DIRECTXTEX_VERSION.tar.gz" "DirectXTex-$DIRECTXTEX_VERSION"
SOURCE="$SRCDIR/DirectXTex-$DIRECTXTEX_VERSION"
# The tools print the version of the library, DIRECTX_TEX_VERSION.
grep -q "^#define DIRECTX_TEX_VERSION $DIRECTXTEX_LIBRARY_VERSION\$" "$SOURCE/DirectXTex/DirectXTex.h" \
  || { echo "DIRECTX_TEX_VERSION of DirectXTex $DIRECTXTEX_VERSION is not $DIRECTXTEX_LIBRARY_VERSION" >&2; exit 1; }

# Empty shaders, under the names CompileShaders.cmd gives them (/Vn).
SHADERS="$WORKDIR/build-directxtex-shaders"
rm -rf "$SHADERS"
mkdir -p "$SHADERS"
for shader in BC7Encode_EncodeBlockCS BC7Encode_TryMode02CS BC7Encode_TryMode137CS BC7Encode_TryMode456CS \
              BC6HEncode_EncodeBlockCS BC6HEncode_TryModeG10CS BC6HEncode_TryModeLE10CS; do
  for suffix in "" _cs40; do
    printf '// Empty: the GPU encoders are not built (scripts/build-directxtex.sh).\nconst BYTE %s[] = { 0 };\n' "$shader" \
      > "$SHADERS/$shader$suffix.inc"
  done
done
grep -h '#include "BC[67]Encode_.*\.inc"' "$SOURCE/DirectXTex/BCDirectCompute.cpp" | sed 's/.*"\(.*\)".*/\1/' | while read -r inc; do
  [ -f "$SHADERS/$inc" ] || { echo "BCDirectCompute.cpp includes $inc, which has no empty shader" >&2; exit 1; }
done

# texconv never creates a Direct3D 11 device: CreateDevice returns false
# after it clears its output, as when there is no device.
TEXCONV="$SOURCE/Texconv/texconv.cpp"
if ! grep -q 'scripts/build-directxtex.sh' "$TEXCONV"; then
  awk '
    /bool CreateDevice\(int adapter, _Outptr_ ID3D11Device\*\* pDevice\) noexcept/ { in_create = 1 }
    { print }
    in_create && /\*pDevice = nullptr;/ {
      print "        // The GPU encoders are not built (scripts/build-directxtex.sh): the CPU encoders only."
      print "        if (adapter != -2) return false;"
      in_create = 0
    }
  ' "$TEXCONV" > "$TEXCONV.tmp" && mv "$TEXCONV.tmp" "$TEXCONV"
fi
grep -q 'scripts/build-directxtex.sh' "$TEXCONV" || { echo "CreateDevice of texconv.cpp was not patched" >&2; exit 1; }

# CMakeLists.txt names Texconv/Texconv.rc texconv.rc, which only a
# case-insensitive file system finds.
[ -f "$SOURCE/Texconv/texconv.rc" ] || cp "$SOURCE/Texconv/Texconv.rc" "$SOURCE/Texconv/texconv.rc"
# The resource files name the icon with backslashes (..\\Common\\directx.ico).
for rc in "$SOURCE"/Texconv/*.rc "$SOURCE"/Texdiag/*.rc "$SOURCE"/Texassemble/*.rc; do
  sed 's#\\\\#/#g' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"
done

# The sources include Windows headers in mixed case (<Windows.h>, ...) and
# with backslashes (<wrl\client.h>), and the MinGW headers are lowercase: a
# directory of forwarding headers, one for each such include, for the
# case-sensitive file system of the Linux machine. The headers of the prefix
# (DirectXMath, DirectX-Headers) are found as they are.
MINGW_INCLUDE="$LLVM_MINGW_ROOT/$MINGW_TRIPLE/include"
[ -d "$MINGW_INCLUDE" ] || MINGW_INCLUDE="$LLVM_MINGW_ROOT/generic-w64-mingw32/include"
[ -f "$MINGW_INCLUDE/windows.h" ] || { echo "no windows.h in $MINGW_INCLUDE" >&2; exit 1; }
CASE_SHIMS="$WORKDIR/build-directxtex-case"
rm -rf "$CASE_SHIMS"
mkdir -p "$CASE_SHIMS"
find "$SOURCE" -name '*.h' -o -name '*.cpp' -o -name '*.inl' \
  | xargs sed -n 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*<\([^>]*\)>.*/\1/p' | sort -u \
  | while read -r header; do
      target="$(echo "$header" | tr 'A-Z\\' 'a-z/')"
      [ "$header" != "$target" ] || continue
      [ -z "$(find "$PREFIX/include" -name "$(basename "$header")" | sed -n 1p)" ] || continue
      if [ ! -f "$MINGW_INCLUDE/$header" ] && [ -f "$MINGW_INCLUDE/$target" ]; then
        printf '#include <%s>\n' "$target" > "$CASE_SHIMS/$header"
      fi
    done
echo "forwarding headers: $(ls "$CASE_SHIMS" | tr '\n' ' ')"

BUILD="$WORKDIR/build-directxtex"
msg "configuring DirectXTex $DIRECTXTEX_VERSION for $TARGET"
rm -rf "$BUILD"
# shellcheck disable=SC2086
cmake -S "$SOURCE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS_ARGS \
  -DCMAKE_PREFIX_PATH="$PREFIX" -DBUILD_SHARED_LIBS=OFF -DBUILD_TOOLS=ON -DBUILD_SAMPLE=OFF \
  -DBUILD_DX11=ON -DBUILD_DX12=OFF -DBC_USE_OPENMP=OFF -DUSE_PREBUILT_SHADERS=ON -DCOMPILED_SHADERS="$SHADERS" \
  -DENABLE_OPENEXR_SUPPORT=OFF -DENABLE_LIBJPEG_SUPPORT=OFF -DENABLE_LIBPNG_SUPPORT=OFF \
  "-DCMAKE_CXX_FLAGS=-I$CASE_SHIMS" \
  "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"

msg "building $TOOLS"
# shellcheck disable=SC2086
cmake --build "$BUILD" --parallel "$JOBS" --target $TOOLS

OUTPUTS=""
for tool in $TOOLS; do
  built="$(find "$BUILD" -type f -name "$tool.exe" | sed -n 1p)"
  [ -n "$built" ] || { echo "$tool.exe was not built in $BUILD" >&2; exit 1; }
  out="$WORKDIR/$tool-$TARGET.exe"
  cp "$built" "$out"
  OUTPUTS="$OUTPUTS $out"
done
# shellcheck disable=SC2086
finish_outputs $OUTPUTS
msg "built $TOOLS for $TARGET"
