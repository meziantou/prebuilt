#!/usr/bin/env bash
#
# Verifies TAppEncoderSCM/TAppDecoderSCM, the HM-SCM encoder and decoder built
# by scripts/build-hm-scm.sh.
#
#   bash scripts/verify-hm-scm.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertions plus the round trips below (must run on the
#         target platform)
#   all   both (default)
#
# The round trips encode pictures of screen content (a few colors in 8 x 8
# blocks) with the screen content coding tools, with an MD5 hash SEI message
# for every picture, and check that the decoder accepts the hashes and writes
# the pictures the encoder reconstructed:
# - main-SCC 4:4:4 8-bit: palette mode, intra block copy (hash search),
#   adaptive color transform and adaptive motion vector resolution;
# - main-SCC 4:2:0 8-bit: palette mode and intra block copy;
# - 4:4:4 10-bit SCC.
#
# HM_SCM_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
[ -n "$HM_SCM_VERSION" ] || { echo "HM_SCM_VERSION is not set" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64) EXE=""; PLATFORM="Linux" ;;
  osx-arm64) EXE=""; PLATFORM="Mac OS X" ;;
  win-x64) EXE=".exe"; PLATFORM="Windows" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

ENCODER="./TAppEncoderSCM-$TARGET$EXE"
DECODER="./TAppDecoderSCM-$TARGET$EXE"
for bin in "$ENCODER" "$DECODER"; do
  [ -f "$bin" ] || { echo "missing $bin" >&2; exit 1; }
  chmod +x "$bin" 2>/dev/null || true
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

# The version is "16.21_SCM8.8" for HM_SCM_VERSION 16.21+8.8.
VERSION_TEXT="${HM_SCM_VERSION%%+*}_SCM${HM_SCM_VERSION#*+}"

assert_version() {
  tool="$1"; bin="$2"; kind="$3"
  status=0
  output="$("$bin" 2>&1 | tr -d '\r')" || status=$?
  [ "$status" -eq 1 ] || fail "$tool without an argument exited with $status instead of 1"
  contains "$output" "HM software: $kind Version [$VERSION_TEXT] (including RExt)" \
    || { echo "$output" | head -n 3 >&2; fail "$tool does not report version $VERSION_TEXT"; }
  contains "$output" "[$PLATFORM]" || fail "$tool was not built for $PLATFORM"
  contains "$output" "[64 bit]" || fail "$tool is not a 64-bit build"
  ok "$tool reports version $VERSION_TEXT, 64-bit $PLATFORM"
}

# plane <width> <height> <bits> <seed>: screen content, 4 levels in 8 x 8
# blocks, one byte per sample up to 8 bits and two (little-endian) above.
plane() {
  plane_y=0
  while [ "$plane_y" -lt "$2" ]; do
    row=""
    plane_x=0
    while [ "$plane_x" -lt "$1" ]; do
      level=$(((plane_x / 8 + plane_y / 8 + $4) % 4))
      if [ "$3" -gt 8 ]; then
        value=$((level * 240 + 16))
        row="$row$(printf '\\%03o\\%03o' $((value & 255)) $((value >> 8)))"
      else
        row="$row$(printf '\\%03o' $((level * 60)))"
      fi
      plane_x=$((plane_x + 1))
    done
    # shellcheck disable=SC2059
    printf "$row"
    plane_y=$((plane_y + 1))
  done
}

# round_trip <name> <bits> <444|420> <pictures> <encoder option>...
round_trip() {
  name="$1"; bits="$2"; chroma="$3"; count="$4"; shift 4
  chroma_size=64
  [ "$chroma" = 420 ] && chroma_size=32
  : > "$name.yuv"
  picture=0
  while [ "$picture" -lt "$count" ]; do
    plane 64 64 "$bits" "$picture" >> "$name.yuv"
    plane "$chroma_size" "$chroma_size" "$bits" $((picture + 1)) >> "$name.yuv"
    plane "$chroma_size" "$chroma_size" "$bits" $((picture + 2)) >> "$name.yuv"
    picture=$((picture + 1))
  done
  "$E" -i "$name.yuv" -b "$name.bin" -o "$name.rec.yuv" \
    --SourceWidth=64 --SourceHeight=64 --FramesToBeEncoded="$count" --FrameRate=30 \
    --InputBitDepth="$bits" --InternalBitDepth="$bits" --InputChromaFormat="$chroma" --ChromaFormatIDC="$chroma" \
    --Profile=main-SCC --Level=4.1 --IntraPeriod=-1 --DecodingRefreshType=1 --GOPSize=1 \
    "--Frame1=P 1 0 0.0 0.0 0 0 1.0 0 0 0 1 1 -1 0" --QP=22 \
    --MaxCUWidth=16 --MaxCUHeight=16 --MaxPartitionDepth=2 --QuadtreeTULog2MaxSize=4 \
    --SEIDecodedPictureHash=1 "$@" > "$name.enc.log" 2>&1 \
    || { cat "$name.enc.log" >&2; fail "$name: TAppEncoderSCM failed"; }
  [ -s "$name.bin" ] || fail "$name: TAppEncoderSCM wrote no stream"
  "$D" -b "$name.bin" -o "$name.dec.yuv" -d 0 > "$name.dec.log" 2>&1 \
    || { cat "$name.dec.log" >&2; fail "$name: TAppDecoderSCM failed"; }
  [ "$(grep -c -F ',(OK)]' "$name.dec.log" || true)" -eq "$count" ] \
    || { cat "$name.dec.log" >&2; fail "$name: the decoder did not check the hash of $count pictures"; }
  cmp -s "$name.rec.yuv" "$name.dec.yuv" || fail "$name: the decoded pictures differ from the reconstruction"
  ok "$name: $chroma $bits-bit, $count pictures, $(file_size "$name.bin") bytes, hashes and reconstruction match"
}

# encoder_reports <name> <text>...
encoder_reports() {
  log="$(tr -d '\r' < "$1.enc.log")"
  shift
  for text in "$@"; do
    contains "$log" "$text" || fail "the encoder does not report '$text'"
    ok "the encoder reports '$text'"
  done
}

tests() {
  workdir="smoke-hm-scm-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  E="../TAppEncoderSCM-$TARGET$EXE"
  D="../TAppDecoderSCM-$TARGET$EXE"

  msg "main-SCC 4:4:4: palette, intra block copy, adaptive color transform, motion vector resolution"
  round_trip scc444 8 444 2 --PaletteMode=1 --IntraBlockCopyEnabled=1 --HashBasedIntraBlockCopySearchEnabled=1 \
    --ColourTransform=1 --MotionVectorResolutionControlIdc=2
  encoder_reports scc444 "Profile                                : main-SCC" \
    "Intra block copying                    : Enabled" "Adaptive colour transform              : Enabled" \
    "Palette mode                           : Enabled" "MvResControl:2"

  msg "main-SCC 4:2:0: palette, intra block copy"
  round_trip scc420 8 420 2 --PaletteMode=1 --IntraBlockCopyEnabled=1 --HashBasedIntraBlockCopySearchEnabled=1
  encoder_reports scc420 "Palette mode                           : Enabled" "Intra block copying                    : Enabled"

  msg "SCC 4:4:4 10-bit"
  round_trip scc444-10 10 444 2 --PaletteMode=1 --IntraBlockCopyEnabled=1 --HashBasedIntraBlockCopySearchEnabled=1 --ColourTransform=1

  cd ..
  ok "all round trips passed"
}

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$ENCODER"
    assert_linkage "$DECODER"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    assert_version TAppEncoderSCM "$ENCODER" Encoder
    assert_version TAppDecoderSCM "$DECODER" Decoder
    tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
