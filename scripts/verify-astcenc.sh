#!/usr/bin/env bash
#
# Verifies astcenc, built by scripts/build-astcenc.sh.
#
#   bash scripts/verify-astcenc.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage and version assertions only
#   run   version assertion plus the tests below (must run on the target)
#   all   both (default)
#
# The tests, with images written byte by byte (TGA for LDR, Radiance HDR for
# HDR):
# - -cl / -cs / -ch / -cH compress LDR linear, LDR sRGB, HDR RGB with LDR
#   alpha and HDR RGBA, and write the .astc header: the magic 13 AB A1 5C, the
#   block size (2D 4x4 to 12x12, 3D NxNxN) and the image size, 24-bit
#   little-endian.
# - -dl / -dh decompress, here to uncompressed KTX files: a solid color is a
#   void-extent block, which gives the color back exactly, 8-bit for LDR and
#   FP16 for HDR.
# - -tl compresses and decompresses, and prints the PSNR.
# - astcenc is built for no SIMD instruction set and is invariant: the bytes
#   of a compressed gradient are pinned, the same on every runtime identifier.
#
# ASTCENC_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
[ -n "$ASTCENC_VERSION" ] || { echo "ASTCENC_VERSION is not set" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

BIN="./astcenc-$TARGET$EXE"
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

# repeat <count> <printf format>: the bytes of the format, <count> times.
repeat() {
  repeat_i=0
  while [ "$repeat_i" -lt "$1" ]; do
    # shellcheck disable=SC2059
    printf "$2"
    repeat_i=$((repeat_i + 1))
  done
}

tests() {
  workdir="smoke-astcenc-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  A="../astcenc-$TARGET$EXE"

  # 16 x 8 TGA files, 32 bits, top-left origin: a gradient (B = 16 x,
  # G = 32 y, R = 8 (x + y)), and a solid color (R 90, G 60, B 30).
  tga_header='\000\000\002\000\000\000\000\000\000\000\000\000\020\000\010\000\040\050'
  {
    printf "$tga_header"
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
  { printf "$tga_header"; repeat 128 '\036\074\132\377'; } > solid.tga
  # 8 x 4 Radiance HDR file, flat scan lines: (2, 1, 0.5) is RGBE 128 64 32 130.
  { printf '#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 4 +X 8\n'; repeat 32 '\200\100\040\202'; } > solid.hdr

  msg "LDR"
  "$A" -cl gradient.tga gradient.astc 6x6 -medium -silent || fail "-cl failed"
  # Magic, block 6x6x1, width 16, height 8, depth 1.
  expect "the .astc header" "$(hex_of_n gradient.astc 16)" "13aba15c060601100000080000010000"
  expect "6x6 blocks: 3 x 2 blocks of 16 bytes" "$(file_size gradient.astc)" "112"
  "$A" -cl gradient.tga gradient-12.astc 12x12 -fast -silent || fail "-cl 12x12 failed"
  expect "the block size of 12x12" "$(hex_of_n gradient-12.astc 7)" "13aba15c0c0c01"
  "$A" -cs gradient.tga gradient-srgb.astc 6x6 -medium -silent || fail "-cs failed"
  cmp -s gradient.astc gradient-srgb.astc && fail "-cs (sRGB) writes the blocks of -cl"
  ok "-cs (sRGB) writes other blocks than -cl"
  "$A" -cl solid.tga solid.astc 4x4 -fast -silent || fail "-cl solid failed"
  "$A" -dl solid.astc solid.ktx -silent || fail "-dl failed"
  repeat 128 '\132\074\036' > solid-expected.raw
  tail -c 384 solid.ktx > solid.raw
  same_file "-dl: a solid color comes back exactly (8-bit RGB)" solid.raw solid-expected.raw
  psnr="$("$A" -tl gradient.tga gradient-t.tga 4x4 -thorough | tr -d '\r' | sed -n 's/^ *PSNR (LDR-RGBA): *\([0-9.]*\) dB$/\1/p')"
  [ -n "$psnr" ] || fail "-tl printed no PSNR"
  awk -v p="$psnr" 'BEGIN { exit !(p > 30) }' || fail "-tl: a PSNR of $psnr dB"
  ok "-tl: PSNR $psnr dB"

  msg "HDR"
  "$A" -ch solid.hdr solid-hdr-rgb.astc 4x4 -fast -silent || fail "-ch failed"
  "$A" -dh solid-hdr-rgb.astc solid-hdr-rgb.ktx -silent || fail "-dh failed"
  # FP16 0.5, 2, 1: 0x3800, 0x4000, 0x3C00.
  repeat 32 '\000\100\000\074\000\070' > hdr-expected.raw
  tail -c 192 solid-hdr-rgb.ktx > hdr.raw
  same_file "-ch / -dh: a solid HDR color comes back exactly (FP16)" hdr.raw hdr-expected.raw
  "$A" -cH solid.hdr solid-hdr-rgba.astc 8x8 -fast -silent || fail "-cH failed"
  expect "-cH: the header of 8x8 blocks" "$(hex_of_n solid-hdr-rgba.astc 16)" "13aba15c080801080000040000010000"
  "$A" -dH solid-hdr-rgba.astc solid-hdr-rgba.ktx -silent || fail "-dH failed"
  tail -c 192 solid-hdr-rgba.ktx > hdr.raw
  same_file "-cH / -dH: the solid HDR color" hdr.raw hdr-expected.raw

  msg "the same bytes on every runtime identifier"
  expect "gradient.astc" "$(sha256_of gradient.astc)" "a1ff2a1b506b96fe64ff5c47fcede7cf7c7dfa3ec246d5a2cc3b37e273e4bd3e"
  "$A" -dl gradient.astc gradient.ktx -silent || fail "-dl gradient failed"
  expect "gradient.ktx" "$(sha256_of gradient.ktx)" "c6a2a18f9134ccd8a6bfc77a1b8c4c3fb71eb00e556221e6dae80c8051b784df"

  cd ..
  ok "all tests passed"
}

case "$MODE" in
  link|all)
    msg "linkage and version ($TARGET)"
    assert_linkage "$BIN"
    # The banner is formatted at run time: the version is a string of its own.
    grep -a -q -F "$ASTCENC_VERSION" "$BIN" || fail "$BIN does not contain '$ASTCENC_VERSION'"
    ok "$BIN contains $ASTCENC_VERSION"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    version="$("$BIN" -version | tr -d '\r' | head -n 1)"
    expect "astcenc -version" "$version" "astcenc v$ASTCENC_VERSION, 64-bit none"
    tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
