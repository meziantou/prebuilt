#!/usr/bin/env bash
#
# Verifies basisu, built by scripts/build-basisu.sh.
#
#   bash scripts/verify-basisu.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage and version assertions only
#   run   version assertion plus the tests below (must run on the target)
#   all   both (default)
#
# The tests, with images written byte by byte (TGA for LDR, Radiance HDR for
# HDR), check the KTX2 header basisu writes (the identifier, then vkFormat,
# typeSize, the size, layerCount, faceCount, levelCount and the
# supercompression scheme):
# - ETC1S (the default): vkFormat 0 (the format of Basis Universal), BasisLZ
#   supercompression (1); -mipmap writes the 5 levels of 16 x 8.
# - -uastc: UASTC LDR 4x4, Zstandard supercompression (2).
# - -hdr: UASTC HDR 4x4 from an HDR file, vkFormat 1000066000
#   (VK_FORMAT_ASTC_4x4_SFLOAT_BLOCK), Zstandard.
# - -info describes them, and -unpack transcodes them to BC1, BC3, BC4, BC5,
#   BC7, ETC1, ETC2, EAC, ASTC and PVRTC1 (.ktx and .dds files) and unpacks
#   them to PNG files; -validate checks them.
# - basisu is built without SSE: the bytes of the files it writes and of a BC7
#   transcode are pinned, the same on every runtime identifier.
#
# BASISU_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
[ -n "$BASISU_VERSION" ] || { echo "BASISU_VERSION is not set" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

BIN="./basisu-$TARGET$EXE"
[ -f "$BIN" ] || { echo "missing $BIN" >&2; exit 1; }
chmod +x "$BIN" 2>/dev/null || true

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

# ktx2_header <file>: vkFormat typeSize width height depth layers faces levels
# supercompression, after the 12-byte identifier.
ktx2_header() {
  [ "$(hex_of_n "$1" 12)" = "ab4b5458203230bb0d0a1a0a" ] || fail "$1 is not a KTX2 file"
  od -An -v -tu4 -j 12 -N 36 "$1" | tr -s ' \n\r' '   ' | sed -e 's/^ //' -e 's/ $//'
}

# basisu_run <label> <arguments...>
basisu_run() {
  label="$1"; shift
  "$B" "$@" > basisu.log 2>&1 || { cat basisu.log >&2; fail "$label: basisu $* failed"; }
}

tests() {
  workdir="smoke-basisu-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  B="../basisu-$TARGET$EXE"

  # A 16 x 8 TGA gradient (32 bits, top-left origin) and an 8 x 4 Radiance HDR
  # solid color (2, 1, 0.5).
  {
    printf '\000\000\002\000\000\000\000\000\000\000\000\000\020\000\010\000\040\050'
    y=0
    while [ "$y" -lt 8 ]; do
      x=0
      while [ "$x" -lt 16 ]; do
        printf "\\$(printf '%03o' $((x * 16 % 256)))\\$(printf '%03o' $((y * 32 % 256)))\\$(printf '%03o' $(((x + y) * 8 % 256)))\\377"
        x=$((x + 1))
      done
      y=$((y + 1))
    done
  } > gradient.tga
  {
    printf '#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 4 +X 8\n'
    i=0
    while [ "$i" -lt 32 ]; do printf '\200\100\040\202'; i=$((i + 1)); done
  } > solid.hdr

  msg "KTX2 files"
  basisu_run "ETC1S" -ktx2 gradient.tga -output_file etc1s.ktx2
  expect "ETC1S: the KTX2 header (BasisLZ)" "$(ktx2_header etc1s.ktx2)" "0 1 16 8 0 0 1 1 1"
  basisu_run "ETC1S mipmaps" -ktx2 -mipmap gradient.tga -output_file etc1s-mipmaps.ktx2
  expect "ETC1S, -mipmap: 5 levels" "$(ktx2_header etc1s-mipmaps.ktx2)" "0 1 16 8 0 0 1 5 1"
  basisu_run "UASTC" -ktx2 -uastc gradient.tga -output_file uastc.ktx2
  expect "UASTC: the KTX2 header (Zstandard)" "$(ktx2_header uastc.ktx2)" "0 1 16 8 0 0 1 1 2"
  basisu_run "UASTC HDR" -ktx2 -hdr solid.hdr -output_file hdr.ktx2
  expect "UASTC HDR 4x4: the KTX2 header" "$(ktx2_header hdr.ktx2)" "1000066000 1 8 4 0 0 1 1 2"
  basisu_run "a .basis file" -basis gradient.tga -output_file gradient.basis
  expect "a .basis file: the signature" "$(hex_of_n gradient.basis 2)" "7342"

  msg "-info"
  basisu_run "-info" -info uastc.ktx2
  info="$(tr -d '\r' < basisu.log)"
  contains "$info" "KTX2 Supercompression Scheme: ZSTANDARD" || fail "-info: no Zstandard supercompression: $info"
  contains "$info" "Library Supercompression Format: UASTC_LDR_4x4" || fail "-info: no UASTC LDR 4x4: $info"
  ok "-info: Zstandard, UASTC LDR 4x4"
  basisu_run "-info" -info etc1s.ktx2
  contains "$(tr -d '\r' < basisu.log)" "KTX2 Supercompression Scheme: BASISLZ" || fail "-info: no BasisLZ: $(cat basisu.log)"
  ok "-info: BasisLZ"
  for file in etc1s.ktx2 etc1s-mipmaps.ktx2 uastc.ktx2 hdr.ktx2 gradient.basis; do
    basisu_run "-validate $file" -validate "$file"
  done
  ok "-validate: the KTX2 and .basis files are valid"

  msg "-unpack"
  mkdir -p unpack
  ( cd unpack && "../$B" -unpack ../uastc.ktx2 > ../basisu.log 2>&1 ) || { cat basisu.log >&2; fail "-unpack failed"; }
  for format in BC1_RGB BC3_RGBA BC4_R BC5_RG BC7_RGBA; do
    [ -s "unpack/uastc_transcoded_${format}_layer_0000.dds" ] || fail "-unpack wrote no $format DDS file"
  done
  for format in ETC1_RGB ETC2_RGBA ETC2_EAC_R11 ETC2_EAC_RG11 ASTC_LDR_4X4_RGBA PVRTC1_4_RGBA; do
    [ -s "unpack/uastc_transcoded_${format}_layer_0000.ktx" ] || fail "-unpack wrote no $format KTX file"
  done
  [ -s unpack/uastc_unpacked_rgba_RGBA32_level_0_face_0_layer0000.png ] || fail "-unpack wrote no RGBA32 PNG file"
  ok "-unpack: BC1, BC3, BC4, BC5, BC7 (DDS), ETC1, ETC2, EAC, ASTC, PVRTC1 (KTX), PNG"

  msg "the same bytes on every runtime identifier"
  expect "etc1s.ktx2" "$(sha256_of etc1s.ktx2)" "$PIN_ETC1S"
  expect "uastc.ktx2" "$(sha256_of uastc.ktx2)" "$PIN_UASTC"
  expect "hdr.ktx2" "$(sha256_of hdr.ktx2)" "$PIN_HDR"
  expect "the BC7 transcode of uastc.ktx2" "$(sha256_of unpack/uastc_transcoded_BC7_RGBA_layer_0000.dds)" "$PIN_BC7"

  cd ..
  ok "all tests passed"
}

PIN_ETC1S="b194716ca76f2e49a31e1ec709d68063a4a9838e2312058a1f3eae07ceb34960"
PIN_UASTC="96da89480a986bd2c5af2bb54b0cd9e81ba8cc64381057df55f39fdf2ca16898"
PIN_HDR="0b528374c79abd5c19b7867a28541e66c25999de7cd262a51053c1fb1d9a2286"
PIN_BC7="293b7958c099d37aa4e7c11275b918194bbc1c47123e2896de61356517aa3db4"

case "$MODE" in
  link|all)
    msg "linkage and version ($TARGET)"
    assert_linkage "$BIN"
    grep -a -q -F "v$BASISU_VERSION" "$BIN" || fail "$BIN does not contain 'v$BASISU_VERSION'"
    ok "$BIN contains v$BASISU_VERSION"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    version="$("$BIN" -version | tr -d '\r' | sed -n 1p)"
    expect "basisu -version" "$version" "Basis Universal LDR/HDR GPU Texture Supercompression System v$BASISU_VERSION.0"
    features="$("$BIN" -version | tr -d '\r' | sed -n 3p)"
    expect "basisu -version: features" "$features" "No SSE, Multithreading: 1, Zstandard support: 1, OpenCL: 0"
    tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
