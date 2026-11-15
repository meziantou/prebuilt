#!/usr/bin/env bash
#
# Verifies texconv, texdiag and texassemble, built by
# scripts/build-directxtex.sh.
#
#   bash scripts/verify-directxtex.sh win-x64 [link|run|all]
#
# Modes:
#   link  static-linkage and version assertions only (on any machine with
#         objdump or llvm-objdump)
#   run   version assertions plus the tests below (on Windows, in Git Bash)
#   all   both (default)
#
# The tests write DDS files from TGA and Radiance HDR files written byte by
# byte, and check their headers (the "DDS " magic, the mip count, the FourCC,
# and the DXGI format and array size of the DX10 header):
# - texconv -f BC1_UNORM ... BC7_UNORM, BC6H_UF16 and BC6H_SF16, with the CPU
#   encoders (the GPU ones are not built): BC1 to BC5 with a legacy FourCC
#   (DXT1, DXT3, DXT5, BC4U, BC5U), BC6H and BC7 with a DX10 header, and BC1
#   with a DX10 header with -dx10;
# - -m 0: the full mip chain of 16 x 16 (5 levels);
# - texassemble cube and array (-dx10): a cube map (DX10 misc flag
#   TEXTURECUBE, an array size of 1 cube) and an array of 6 layers; texconv
#   compresses the cube map to BC7, with its mip levels;
# - texdiag info describes them, and texconv decodes a BC1 file of a solid
#   color (565) back to the same color;
# - the bytes of BC1, BC7 and BC6H files are pinned.
#
# DIRECTXTEX_VERSION comes from the environment (see .github/workflows/ci.yml);
# the tools print the version of the library, DIRECTXTEX_LIBRARY_VERSION.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ "$TARGET" = win-x64 ] || { echo "usage: $0 win-x64 [link|run|all]" >&2; exit 2; }
for name in DIRECTXTEX_VERSION DIRECTXTEX_LIBRARY_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done
EXE=".exe"

TOOLS="texconv texdiag texassemble"
for tool in $TOOLS; do
  [ -f "./$tool-$TARGET$EXE" ] || { echo "missing ./$tool-$TARGET$EXE" >&2; exit 1; }
done

export LC_ALL=C
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

msg()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m %s\n' "$*"; }

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# shellcheck source=verify-common.sh
. "$SCRIPT_DIR/verify-common.sh"

u32() { od -An -v -tu4 -j "$2" -N 4 "$1" | tr -d ' \r\n'; }

# dds_header <file>: height width mips fourcc [dxgiFormat dimension misc arraySize]
dds_header() {
  [ "$(od -An -c -N 4 "$1" | tr -d ' ')" = "DDS" ] || fail "$1 is not a DDS file"
  fourcc="$(od -An -c -j 84 -N 4 "$1" | tr -d ' ')"
  header="$(u32 "$1" 12) $(u32 "$1" 16) $(u32 "$1" 28) $fourcc"
  [ "$fourcc" = DX10 ] && header="$header $(u32 "$1" 128) $(u32 "$1" 132) $(u32 "$1" 136) $(u32 "$1" 140)"
  echo "$header"
}

# tga <file> <r> <g> <b> [gradient]: a 16 x 16 TGA file, 32 bits, top-left
# origin, of a solid color or of a gradient.
tga() {
  {
    printf '\000\000\002\000\000\000\000\000\000\000\000\000\020\000\020\000\040\050'
    y=0
    while [ "$y" -lt 16 ]; do
      row=""
      x=0
      while [ "$x" -lt 16 ]; do
        if [ -n "$5" ]; then
          row="$row$(printf '\\%03o\\%03o\\%03o\\377' $((x * 16 % 256)) $((y * 16 % 256)) $(((x + y) * 8 % 256)))"
        else
          row="$row$(printf '\\%03o\\%03o\\%03o\\377' "$4" "$3" "$2")"
        fi
        x=$((x + 1))
      done
      # shellcheck disable=SC2059
      printf "$row"
      y=$((y + 1))
    done
  } > "$1"
}

# conv <label> <texconv options...>: texconv, CPU encoders only.
conv() {
  conv_label="$1"; shift
  "$T" -nologo -y "$@" > tool.log 2>&1 || { cat tool.log >&2; fail "$conv_label: texconv $* failed"; }
}

tests() {
  workdir="smoke-directxtex-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  T="../texconv-$TARGET$EXE"
  D="../texdiag-$TARGET$EXE"
  A="../texassemble-$TARGET$EXE"

  tga gradient.tga 0 0 0 gradient
  # 0x08 0x41 0x08 in 565 is (8, 65, 8): 8-bit values a 565 color holds exactly.
  tga solid.tga 8 65 8
  # 16 x 16 Radiance HDR: (2, 1, 0.5).
  {
    printf '#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 16 +X 16\n'
    i=0
    while [ "$i" -lt 256 ]; do printf '\200\100\040\202'; i=$((i + 1)); done
  } > solid.hdr

  msg "texconv: BC1 to BC7"
  for case in "BC1_UNORM:DXT1" "BC2_UNORM:DXT3" "BC3_UNORM:DXT5" "BC4_UNORM:BC4U" "BC5_UNORM:BC5U" "BC7_UNORM:DX10 98 3 0 1"; do
    format="${case%%:*}"; expected="${case#*:}"
    mkdir -p "$format"
    conv "$format" -f "$format" -m 1 -o "$format" gradient.tga
    expect "$format: the DDS header" "$(dds_header "$format/gradient.dds")" "16 16 1 $expected"
  done
  mkdir -p dx10
  conv "BC1 -dx10" -f BC1_UNORM -m 1 -dx10 -o dx10 gradient.tga
  expect "BC1_UNORM with -dx10: DXGI_FORMAT_BC1_UNORM (71)" "$(dds_header dx10/gradient.dds)" "16 16 1 DX10 71 3 0 1"

  msg "texconv: BC6H"
  for case in "BC6H_UF16:95" "BC6H_SF16:96"; do
    format="${case%%:*}"
    mkdir -p "$format"
    conv "$format" -f "$format" -m 1 -o "$format" solid.hdr
    expect "$format: the DDS header" "$(dds_header "$format/solid.dds")" "16 16 1 DX10 ${case#*:} 3 0 1"
  done

  msg "texconv: mipmaps"
  mkdir -p mips
  conv "mipmaps" -f BC1_UNORM -m 0 -o mips gradient.tga
  expect "-m 0: 5 levels" "$(dds_header mips/gradient.dds)" "16 16 5 DXT1"

  msg "texassemble: cube map and array"
  for f in 0 1 2 3 4 5; do tga "face$f.tga" $((f * 40)) $((255 - f * 40)) $((f * 10)); done
  "$A" cube -nologo -y -dx10 -o cube.dds face0.tga face1.tga face2.tga face3.tga face4.tga face5.tga > tool.log 2>&1 \
    || { cat tool.log >&2; fail "texassemble cube failed"; }
  # A cube map: the misc flag TEXTURECUBE (4), an array size of 1 cube.
  expect "a cube map" "$(dds_header cube.dds | cut -d ' ' -f 4-)" "DX10 28 3 4 1"
  "$A" array -nologo -y -dx10 -o array.dds face0.tga face1.tga face2.tga face3.tga face4.tga face5.tga > tool.log 2>&1 \
    || { cat tool.log >&2; fail "texassemble array failed"; }
  expect "an array of 6 layers" "$(dds_header array.dds | cut -d ' ' -f 4-)" "DX10 28 3 0 6"
  mkdir -p cube-bc7
  conv "cube BC7" -f BC7_UNORM -o cube-bc7 cube.dds
  expect "the cube map in BC7, with 5 levels" "$(dds_header cube-bc7/cube.dds)" "16 16 5 DX10 98 3 4 1"

  msg "texdiag"
  info="$("$D" info -nologo cube-bc7/cube.dds | tr -d '\r')"
  # texdiag counts the faces of a cube map in its array size.
  for text in "width = 16" "height = 16" "mipLevels = 5" "arraySize = 6" "format = BC7_UNORM" "dimension = Cube"; do
    contains "$info" "$text" || fail "texdiag info has no '$text': $info"
    ok "texdiag info: $text"
  done
  info="$("$D" info -nologo array.dds | tr -d '\r')"
  contains "$info" "arraySize = 6" || fail "texdiag info of the array: $info"
  contains "$info" "dimension = 2DArray" || fail "texdiag info of the array: $info"
  ok "texdiag info: arraySize = 6, 2DArray"

  msg "texconv: decoding"
  mkdir -p solid-bc1 solid-tga
  conv "solid BC1" -f BC1_UNORM -m 1 -o solid-bc1 solid.tga
  conv "decode BC1" -ft tga -f R8G8B8A8_UNORM -o solid-tga solid-bc1/solid.dds
  # The TGA file texconv writes: 18-byte header, then BGRA (or BGR) pixels.
  size="$(file_size solid-tga/solid.tga)"
  [ "$size" -ge 1024 ] || fail "the decoded TGA file has $size bytes"
  pixel="$(od -An -v -tu1 -j 18 -N 3 solid-tga/solid.tga | tr -s ' ' ' ' | sed 's/^ //;s/ $//')"
  expect "BC1 of a 565 color decodes to that color (B G R)" "$pixel" "8 65 8"

  msg "the same bytes on every machine"
  expect "BC1_UNORM/gradient.dds" "$(sha256_of BC1_UNORM/gradient.dds)" "$PIN_BC1"
  expect "BC7_UNORM/gradient.dds" "$(sha256_of BC7_UNORM/gradient.dds)" "$PIN_BC7"
  expect "BC6H_UF16/solid.dds" "$(sha256_of BC6H_UF16/solid.dds)" "$PIN_BC6H"

  cd ..
  ok "all tests passed"
}

PIN_BC1="8a946cc4c62690b7d60b26a229524b01cf2b3825ef123a53fadd4f8d114d3a4c"
PIN_BC7="34ea72559d1dcb6882e834aff1e871467e2b87a66c53b46d881b5e2439284e76"
PIN_BC6H="e2710abce1287d7ed6a7b9d31b87b764fdaba7b2d3f13df7f57fe7c20c9c13a6"

case "$MODE" in
  link|all)
    msg "linkage and version ($TARGET)"
    for tool in $TOOLS; do
      assert_linkage "./$tool-$TARGET$EXE"
    done
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    expect "texconv --version" "$("./texconv-$TARGET$EXE" --version | tr -d '\r' | head -n 1)" "texconv version $DIRECTXTEX_LIBRARY_VERSION (library)"
    for tool in texdiag texassemble; do
      banner="$("./$tool-$TARGET$EXE" 2>&1 | tr -d '\r' | head -n 1 || true)"
      contains "$banner" "[DirectXTex] Version $DIRECTXTEX_LIBRARY_VERSION" || fail "$tool: $banner"
      ok "$tool: $banner"
    done
    tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
