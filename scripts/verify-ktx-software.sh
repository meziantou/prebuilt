#!/usr/bin/env bash
#
# Verifies ktx, toktx and ktx2check, built by scripts/build-ktx-software.sh.
#
#   bash scripts/verify-ktx-software.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage and version assertions only
#   run   version assertions plus the tests below (must run on the target)
#   all   both (default)
#
# The tests write KTX2 files from raw samples written byte by byte (ktx create
# --raw, one input file per level, layer and face) and from a PAM file
# (toktx), check their header (vkFormat, typeSize, size, layerCount,
# faceCount, levelCount, supercompression scheme), check them with
# `ktx validate` and ktx2check, and read them back with `ktx extract --raw`:
# - uncompressed R8G8B8A8, and with Zstandard supercompression (2), which
#   gives the samples back;
# - 5 mip levels, a cube map (6 faces) and an array of 6 layers: each level,
#   face and layer comes back;
# - Basis Universal: ETC1S (--encode basis-lz, BasisLZ supercompression, 1),
#   and UASTC with Zstandard, transcoded to RGBA8 with `ktx transcode`;
# - toktx: mipmaps generated from a PAM file, UASTC, Zstandard;
# - a file that is not KTX2 fails `ktx validate` (exit code 3) and ktx2check
#   (2).
# The encoders are built for no SIMD instruction set, and ktx create --testrun
# writes no version: the bytes of the files are pinned, the same on every
# runtime identifier.
#
# KTX_SOFTWARE_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
[ -n "$KTX_SOFTWARE_VERSION" ] || { echo "KTX_SOFTWARE_VERSION is not set" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

TOOLS="ktx toktx ktx2check"
for tool in $TOOLS; do
  [ -f "./$tool-$TARGET$EXE" ] || { echo "missing ./$tool-$TARGET$EXE" >&2; exit 1; }
  chmod +x "./$tool-$TARGET$EXE" 2>/dev/null || true
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

# ktx2_header <file>: vkFormat typeSize width height depth layers faces levels
# supercompression, after the 12-byte identifier.
ktx2_header() {
  [ "$(hex_of_n "$1" 12)" = "ab4b5458203230bb0d0a1a0a" ] || fail "$1 is not a KTX2 file"
  od -An -v -tu4 -j 12 -N 36 "$1" | tr -s ' \n\r' '   ' | sed -e 's/^ //' -e 's/ $//'
}

# solid <file> <pixels> <r> <g> <b> <a>
solid() {
  solid_format="$(printf '\\%03o\\%03o\\%03o\\%03o' "$3" "$4" "$5" "$6")"
  solid_i=0
  : > "$1"
  while [ "$solid_i" -lt "$2" ]; do
    # shellcheck disable=SC2059
    printf "$solid_format" >> "$1"
    solid_i=$((solid_i + 1))
  done
}

# checked <label> <file>: ktx validate and ktx2check accept the file.
checked() {
  "$K" validate "$2" > validate.log 2>&1 || { cat validate.log >&2; fail "$1: ktx validate rejects $2"; }
  "$KTX2CHECK" "$2" > validate.log 2>&1 || { cat validate.log >&2; fail "$1: ktx2check rejects $2"; }
  ok "$1: ktx validate and ktx2check accept it"
}

# run <label> <binary> <arguments...>
run() {
  run_label="$1"; shift
  "$@" > tool.log 2>&1 || { cat tool.log >&2; fail "$run_label failed: $*"; }
}

tests() {
  workdir="smoke-ktx-software-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  K="../ktx-$TARGET$EXE"
  TOKTX="../toktx-$TARGET$EXE"
  KTX2CHECK="../ktx2check-$TARGET$EXE"

  # 16 x 8 RGBA samples: R = 16 x, G = 32 y, B = 8 (x + y), A = 255; as raw
  # samples and as a PAM file.
  {
    y=0
    while [ "$y" -lt 8 ]; do
      x=0
      while [ "$x" -lt 16 ]; do
        printf "\\$(printf '%03o' $((x * 16 % 256)))\\$(printf '%03o' $((y * 32 % 256)))\\$(printf '%03o' $(((x + y) * 8 % 256)))\\377"
        x=$((x + 1))
      done
      y=$((y + 1))
    done
  } > rgba.raw
  { printf 'P7\nWIDTH 16\nHEIGHT 8\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n'; cat rgba.raw; } > rgba.pam
  # 6 solid 8 x 8 images (faces, layers), and the 5 levels of 16 x 8.
  for f in 0 1 2 3 4 5; do solid "f$f.raw" 64 $((f * 40)) $((255 - f * 40)) $((f * 10)) 255; done
  solid l0.raw 128 0 10 20 255
  solid l1.raw 32 50 10 20 255
  solid l2.raw 8 100 10 20 255
  solid l3.raw 2 150 10 20 255
  solid l4.raw 1 200 10 20 255

  RAW="--testrun --raw --format R8G8B8A8_UNORM"

  msg "ktx create, uncompressed and Zstandard"
  run "ktx create" "$K" create $RAW --width 16 --height 8 rgba.raw plain.ktx2
  expect "R8G8B8A8_UNORM (37): the KTX2 header" "$(ktx2_header plain.ktx2)" "37 1 16 8 0 0 1 1 0"
  checked "plain.ktx2" plain.ktx2
  run "ktx extract" "$K" extract --raw plain.ktx2 plain.raw
  same_file "ktx extract --raw gives the samples back" plain.raw rgba.raw
  run "ktx create --zstd" "$K" create $RAW --width 16 --height 8 --zstd 18 rgba.raw zstd.ktx2
  expect "--zstd 18: Zstandard supercompression (2)" "$(ktx2_header zstd.ktx2)" "37 1 16 8 0 0 1 1 2"
  checked "zstd.ktx2" zstd.ktx2
  run "ktx extract" "$K" extract --raw zstd.ktx2 zstd.raw
  same_file "Zstandard gives the samples back" zstd.raw rgba.raw
  info="$("$K" info -f mini-json zstd.ktx2 | tr -d '\r')"
  contains "$info" '"vkFormat":"VK_FORMAT_R8G8B8A8_UNORM"' || fail "ktx info: $info"
  contains "$info" '"supercompressionScheme":"KTX_SS_ZSTD"' || fail "ktx info: $info"
  ok "ktx info -f mini-json: VK_FORMAT_R8G8B8A8_UNORM, KTX_SS_ZSTD"

  msg "mip levels, cube map, array"
  run "ktx create --levels 5" "$K" create $RAW --width 16 --height 8 --levels 5 l0.raw l1.raw l2.raw l3.raw l4.raw levels.ktx2
  expect "5 levels" "$(ktx2_header levels.ktx2)" "37 1 16 8 0 0 1 5 0"
  checked "levels.ktx2" levels.ktx2
  run "ktx extract --level 2" "$K" extract --raw --level 2 levels.ktx2 level2.raw
  same_file "level 2 (4 x 2)" level2.raw l2.raw
  run "ktx create --cubemap" "$K" create $RAW --width 8 --height 8 --cubemap f0.raw f1.raw f2.raw f3.raw f4.raw f5.raw cube.ktx2
  expect "a cube map: 6 faces" "$(ktx2_header cube.ktx2)" "37 1 8 8 0 0 6 1 0"
  checked "cube.ktx2" cube.ktx2
  run "ktx extract --face 3" "$K" extract --raw --face 3 cube.ktx2 face3.raw
  same_file "face 3" face3.raw f3.raw
  run "ktx create --layers 6" "$K" create $RAW --width 8 --height 8 --layers 6 f0.raw f1.raw f2.raw f3.raw f4.raw f5.raw array.ktx2
  expect "an array: 6 layers" "$(ktx2_header array.ktx2)" "37 1 8 8 0 6 1 1 0"
  checked "array.ktx2" array.ktx2
  run "ktx extract --layer 4" "$K" extract --raw --layer 4 array.ktx2 layer4.raw
  same_file "layer 4" layer4.raw f4.raw

  msg "Basis Universal"
  run "ktx create --encode basis-lz" "$K" create --testrun --raw --format R8G8B8A8_SRGB --width 16 --height 8 --encode basis-lz rgba.raw etc1s.ktx2
  expect "ETC1S: BasisLZ supercompression (1)" "$(ktx2_header etc1s.ktx2)" "0 1 16 8 0 0 1 1 1"
  checked "etc1s.ktx2" etc1s.ktx2
  run "ktx create --encode uastc" "$K" create $RAW --width 16 --height 8 --encode uastc --zstd 10 rgba.raw uastc.ktx2
  expect "UASTC with Zstandard" "$(ktx2_header uastc.ktx2)" "0 1 16 8 0 0 1 1 2"
  checked "uastc.ktx2" uastc.ktx2
  run "ktx transcode" "$K" transcode --target rgba8 uastc.ktx2 uastc-rgba8.ktx2
  expect "ktx transcode --target rgba8" "$(ktx2_header uastc-rgba8.ktx2)" "37 1 16 8 0 0 1 1 0"
  run "ktx extract" "$K" extract --raw uastc-rgba8.ktx2 uastc.raw
  expect "the transcoded samples: 16 x 8 x 4 bytes" "$(file_size uastc.raw)" "512"

  msg "toktx"
  run "toktx" "$TOKTX" --t2 --genmipmap --encode uastc --zcmp 10 toktx.ktx2 rgba.pam
  expect "toktx --genmipmap --encode uastc --zcmp: 5 levels, Zstandard" "$(ktx2_header toktx.ktx2)" "0 1 16 8 0 0 1 5 2"
  checked "toktx.ktx2" toktx.ktx2

  msg "invalid files"
  printf 'not a KTX2 file' > invalid.ktx2
  status=0; "$K" validate invalid.ktx2 > validate.log 2>&1 || status=$?
  expect "ktx validate of a file that is not KTX2: exit code" "$status" "3"
  status=0; "$KTX2CHECK" invalid.ktx2 > validate.log 2>&1 || status=$?
  expect "ktx2check of a file that is not KTX2: exit code" "$status" "2"

  msg "the same bytes on every runtime identifier"
  expect "plain.ktx2" "$(sha256_of plain.ktx2)" "b2b999eb4bdeea230fbbec7debd45e6978373299a090d47bb82fbe67dd37c56e"
  expect "etc1s.ktx2" "$(sha256_of etc1s.ktx2)" "$PIN_ETC1S"
  expect "uastc.ktx2" "$(sha256_of uastc.ktx2)" "$PIN_UASTC"

  cd ..
  ok "all tests passed"
}

PIN_ETC1S="aac4aafbcb86e69700a2fe690f62b403d1a28926e5ab4f5cd347b3eae6517004"
PIN_UASTC="352d444748d78d32a30471f2adbeb0c7c4ed7b3ef11357775d1f8ba47216fe2d"

case "$MODE" in
  link|all)
    msg "linkage and version ($TARGET)"
    for tool in $TOOLS; do
      assert_linkage "./$tool-$TARGET$EXE"
      grep -a -q -F "v$KTX_SOFTWARE_VERSION" "./$tool-$TARGET$EXE" || fail "$tool does not contain 'v$KTX_SOFTWARE_VERSION'"
      ok "$tool contains v$KTX_SOFTWARE_VERSION"
    done
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    expect "ktx --version" "$("./ktx-$TARGET$EXE" --version | tr -d '\r')" "ktx version: v$KTX_SOFTWARE_VERSION"
    # toktx and ktx2check print the name of their file first.
    for tool in toktx ktx2check; do
      version="$("./$tool-$TARGET$EXE" --version 2>&1 | tr -d '\r')"
      case "$version" in
        *" v$KTX_SOFTWARE_VERSION") ok "$tool --version: $version" ;;
        *) fail "$tool --version: $version" ;;
      esac
    done
    tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
