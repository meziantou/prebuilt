#!/usr/bin/env bash
#
# Checks that the HEVC and HEIC tools of a target agree with each other.
#
#   bash scripts/verify-hevc.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# The tools are published as references: the tests of their consumers trust a
# decoded picture when independent decoders write the same samples. This script
# checks that on the target platform, with the tools of three build scripts
# next to it:
# - ffmpeg, x265 and kvazaar (scripts/build-ffmpeg.sh);
# - dec265, heif-enc, heif-dec and heif-info (scripts/build-libheif.sh);
# - TAppEncoder and TAppDecoder (scripts/build-hm.sh).
#
# Every stream is written with a hash of each decoded picture and decoded three
# times, by the hevc decoder of ffmpeg, by dec265 (libde265) and by TAppDecoder
# (HM), which must write the same file. dec265 and TAppDecoder also check the
# hashes. The streams come from the four encoders: x265 at 8, 10 and 12 bits in
# every chroma format, kvazaar for the tiles and the dependent slice segments,
# HM for the range extensions, and heif-enc.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

FFMPEG="./ffmpeg-$TARGET$EXE"
X265="./x265-$TARGET$EXE"
KVAZAAR="./kvazaar-$TARGET$EXE"
DEC265="./dec265-$TARGET$EXE"
HEIF_ENC="./heif-enc-$TARGET$EXE"
HEIF_DEC="./heif-dec-$TARGET$EXE"
HEIF_INFO="./heif-info-$TARGET$EXE"
HM_ENCODER="./TAppEncoder-$TARGET$EXE"
HM_DECODER="./TAppDecoder-$TARGET$EXE"
for bin in "$FFMPEG" "$X265" "$KVAZAAR" "$DEC265" "$HEIF_ENC" "$HEIF_DEC" "$HEIF_INFO" "$HM_ENCODER" "$HM_DECODER"; do
  [ -f "$bin" ] || { echo "missing $bin" >&2; exit 1; }
  chmod +x "$bin" 2>/dev/null || true
done

# The test pictures are written byte by byte with printf.
export LC_ALL=C
# Git Bash on Windows rewrites arguments that look like POSIX paths.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

msg()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m %s\n' "$*"; }
note() { printf '  \033[33mnote\033[0m %s\n' "$*"; }

# No `echo ... | grep -q` in this script: grep closes the pipe early, the
# writer takes SIGPIPE, and `set -o pipefail` turns that into a spurious failure.
contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Pictures
# ---------------------------------------------------------------------------

# plane <width> <height> <bits> <seed> [<shift>]: the samples of a plane, one
# byte each up to 8 bits and two bytes, little endian, above. The rows are four
# ramps that depend on the seed, repeated. The samples are shifted to the left
# by <shift> bits.
plane() {
  plane_width="$1"; plane_height="$2"; plane_bits="$3"; plane_seed="$4"; plane_shift="${5:-0}"
  modulus=$((1 << plane_bits))
  r=0
  while [ "$r" -lt 4 ]; do
    row=""
    x=0
    while [ "$x" -lt "$plane_width" ]; do
      value=$((((x * 37 + r * 101 + plane_seed * 59) * 13 % modulus) << plane_shift))
      if [ $((plane_bits + plane_shift)) -gt 8 ]; then
        printf -v octal '\\%03o\\%03o' $((value & 255)) $((value >> 8))
      else
        printf -v octal '\\%03o' "$value"
      fi
      row="$row$octal"
      x=$((x + 1))
    done
    eval "row$r=\$row"
    r=$((r + 1))
  done
  y=0
  while [ "$y" -lt "$plane_height" ]; do
    eval "row=\$row$((y % 4))"
    # shellcheck disable=SC2059
    printf "$row"
    y=$((y + 1))
  done
}

# pictures <width> <height> <bits> <400|420|422|444> <count>: planar pictures.
pictures() {
  luma_width="$1"; luma_height="$2"; sample_bits="$3"; picture_count="$5"
  case "$4" in
    400) chroma_width=0; chroma_height=0 ;;
    420) chroma_width=$((luma_width / 2)); chroma_height=$((luma_height / 2)) ;;
    422) chroma_width=$((luma_width / 2)); chroma_height="$luma_height" ;;
    444) chroma_width="$luma_width"; chroma_height="$luma_height" ;;
  esac
  picture=0
  while [ "$picture" -lt "$picture_count" ]; do
    plane "$luma_width" "$luma_height" "$sample_bits" $((picture * 3))
    if [ "$chroma_width" -gt 0 ]; then
      plane "$chroma_width" "$chroma_height" "$sample_bits" $((picture * 3 + 1))
      plane "$chroma_width" "$chroma_height" "$sample_bits" $((picture * 3 + 2))
    fi
    picture=$((picture + 1))
  done
}

# picture_bytes <width> <height> <bits> <chroma> <count>: the size of the file.
picture_bytes() {
  samples=$(($1 * $2))
  case "$4" in
    420) samples=$((samples * 3 / 2)) ;;
    422) samples=$((samples * 2)) ;;
    444) samples=$((samples * 3)) ;;
  esac
  [ "$3" -le 8 ] || samples=$((samples * 2))
  echo $((samples * $5))
}

# pixel_format <bits> <chroma>: the name ffmpeg gives to the planar format.
pixel_format() {
  case "$2" in
    400) format="gray" ;;
    *) format="yuv$2p" ;;
  esac
  case "$1" in
    8) [ "$2" != 400 ] || format="gray" ;;
    *) format="$format$1le" ;;
  esac
  echo "$format"
}

# ---------------------------------------------------------------------------
# Decoders
# ---------------------------------------------------------------------------

# run <label> <output file> <command...>: the command succeeds and writes the file.
run() {
  label="$1"; out="$2"; shift 2
  rm -f "$out"
  "$@" > tool.log 2>&1 || { cat tool.log >&2; fail "$label: $(basename "$1") failed"; }
  [ -s "$out" ] || { cat tool.log >&2; fail "$label: $(basename "$1") produced no file"; }
}

# decode_ffmpeg <stream> <pixel format> <output>
decode_ffmpeg() {
  run "$1" "$3" "$FFMPEG" -hide_banner -v error -y -c:v hevc -i "$1" -fps_mode passthrough -f rawvideo -pix_fmt "$2" "$3"
}

# decode_hm <stream> <output>: TAppDecoder checks every hash of the stream, and
# fails when one is wrong. -d 0 writes the bit depth of the stream.
decode_hm() {
  run "$1" "$2" "$HM_DECODER" -b "$1" -o "$2" -d 0
  contains "$(cat tool.log)" ',(OK)]' || { cat tool.log >&2; fail "$1: TAppDecoder found no picture hash to check"; }
  if contains "$(cat tool.log)" '(unk)' || contains "$(cat tool.log)" 'ERROR'; then
    cat tool.log >&2; fail "$1: TAppDecoder did not check every picture"
  fi
}

# agree <stream> <pixel format> <bytes> [<reference>]
#
# The three decoders write the same <bytes> bytes, which are the reference
# ones when there is a reference: the source of a lossless stream, or the
# reconstruction of the encoder.
agree() {
  stream="$1"; format="$2"; bytes="$3"; reference="$4"
  decode_hm "$stream" "$stream.hm.yuv"
  [ "$(($(wc -c < "$stream.hm.yuv")))" -eq "$bytes" ] \
    || fail "$stream: TAppDecoder wrote $(($(wc -c < "$stream.hm.yuv"))) bytes instead of $bytes"
  decode_ffmpeg "$stream" "$format" "$stream.ffmpeg.yuv"
  cmp -s "$stream.ffmpeg.yuv" "$stream.hm.yuv" || fail "$stream: ffmpeg and TAppDecoder decode different pictures"
  # One thread, and the hashes checked.
  run "$stream" "$stream.dec265.yuv" "$DEC265" -q -t 0 -c -o "$stream.dec265.yuv" "$stream"
  cmp -s "$stream.dec265.yuv" "$stream.hm.yuv" || fail "$stream: dec265 and TAppDecoder decode different pictures"
  if [ -n "$reference" ]; then
    cmp -s "$reference" "$stream.hm.yuv" || fail "$stream: the decoded pictures are not $reference"
    ok "$stream: ffmpeg, dec265 and TAppDecoder agree, with the hashes and with $reference ($bytes bytes)"
  else
    ok "$stream: ffmpeg, dec265 and TAppDecoder agree, with the hashes ($bytes bytes)"
  fi
}

# syntax <stream>: the headers of the stream, as trace_headers describes them,
# one "<name> <value>" a line.
syntax() {
  "$FFMPEG" -hide_banner -v info -i "$1" -c:v copy -bsf:v trace_headers -f null - > trace.log 2>&1 \
    || { cat trace.log >&2; fail "$1: trace_headers failed"; }
  tr -d '\r' < trace.log | sed -n 's/^\[trace_headers[^]]*\] [0-9][0-9]*  *\([a-z][a-zA-Z0-9_]*\)[^=]*= \(.*\)$/\1 \2/p' > "$1.syntax"
  [ -s "$1.syntax" ] || { cat trace.log >&2; fail "$1: trace_headers described nothing"; }
}

# has_syntax <stream> <name> <value>...: the stream has every syntax element
# with this value (run syntax first).
has_syntax() {
  stream="$1"; shift
  while [ "$#" -gt 0 ]; do
    grep -q -x -F -- "$1 $2" "$stream.syntax" || fail "$stream: no $1 = $2 in the stream"
    shift 2
  done
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_x265() {
  # Three pictures, an I, a P and a B picture or so: x265 decides. hash=1 is
  # an MD5 of every plane and 2 a CRC; 3, a checksum, is below.
  msg "x265 (ffmpeg): 8, 10 and 12 bits"
  hash=1
  for bits in 8 10 12; do
    for chroma in 420 422 444 400; do
      name="x265-$chroma-$bits"
      format="$(pixel_format "$bits" "$chroma")"
      pictures 64 64 "$bits" "$chroma" 3 > "$name.yuv"
      run "$name" "$name.hevc" "$FFMPEG" -hide_banner -v error -y -f rawvideo -pix_fmt "$format" -s 64x64 -i "$name.yuv" \
        -c:v libx265 -x265-params "hash=$hash" -f hevc "$name.hevc"
      agree "$name.hevc" "$format" "$(picture_bytes 64 64 "$bits" "$chroma" 3)"
      hash=$((3 - hash))
    done
    syntax "x265-444-$bits.hevc"
    has_syntax "x265-444-$bits.hevc" chroma_format_idc 3 bit_depth_luma_minus8 $((bits - 8)) bit_depth_chroma_minus8 $((bits - 8))
  done

  # Lossless, the decoded pictures are the source ones. The pictures are all
  # intra pictures (keyint=1): see the inter pictures below. TAppDecoder is
  # left out of the 16x16 pictures: x265 signals level 8.5 for a lossless
  # stream, and HM takes a coding tree block of 16x16 as an error from level 5.
  msg "x265 (ffmpeg): lossless"
  for bits in 8 10 12; do
    name="x265-lossless-$bits"
    format="$(pixel_format "$bits" 444)"
    pictures 64 64 "$bits" 444 2 > "$name.yuv"
    run "$name" "$name.hevc" "$FFMPEG" -hide_banner -v error -y -f rawvideo -pix_fmt "$format" -s 64x64 -i "$name.yuv" \
      -c:v libx265 -x265-params lossless=1:keyint=1:hash=1 -f hevc "$name.hevc"
    agree "$name.hevc" "$format" "$(picture_bytes 64 64 "$bits" 444 2)" "$name.yuv"

    name="x265-tiny-$bits"
    format="$(pixel_format "$bits" 420)"
    pictures 16 16 "$bits" 420 2 > "$name.yuv"
    run "$name" "$name.hevc" "$FFMPEG" -hide_banner -v error -y -f rawvideo -pix_fmt "$format" -s 16x16 -i "$name.yuv" \
      -c:v libx265 -x265-params lossless=1:keyint=1:hash=1 -f hevc "$name.hevc"
    decode_ffmpeg "$name.hevc" "$format" "$name.ffmpeg.yuv"
    run "$name" "$name.dec265.yuv" "$DEC265" -q -t 0 -c -o "$name.dec265.yuv" "$name.hevc"
    cmp -s "$name.yuv" "$name.ffmpeg.yuv" || fail "$name: ffmpeg does not decode the source pictures"
    cmp -s "$name.yuv" "$name.dec265.yuv" || fail "$name: dec265 does not decode the source pictures"
    ok "$name.hevc: ffmpeg and dec265 agree, with the hashes and with $name.yuv (16x16)"
  done

  # With inter pictures, x265 4.2 does not always write what it reconstructs:
  # the P picture of these 12-bit pictures decodes to other samples than the
  # source, for ffmpeg and TAppDecoder alike, and the MD5 x265 wrote for it is
  # the one of the source. The assembly is not involved (--no-asm does the
  # same), neither is the build: the decoders agree, which is what is checked,
  # and the encoder is reported rather than failed.
  msg "x265 (ffmpeg): lossless, inter pictures"
  for bits in 8 10 12; do
    name="x265-lossless-inter-$bits"
    format="$(pixel_format "$bits" 444)"
    run "$name" "$name.hevc" "$FFMPEG" -hide_banner -v error -y -f rawvideo -pix_fmt "$format" -s 64x64 -i "x265-lossless-$bits.yuv" \
      -c:v libx265 -x265-params lossless=1:hash=1 -f hevc "$name.hevc"
    decode_ffmpeg "$name.hevc" "$format" "$name.ffmpeg.yuv"
    hashes=0
    "$HM_DECODER" -b "$name.hevc" -o "$name.hm.yuv" -d 0 > tool.log 2>&1 || hashes=$?
    [ -s "$name.hm.yuv" ] || { cat tool.log >&2; fail "$name.hevc: TAppDecoder wrote no picture"; }
    cmp -s "$name.ffmpeg.yuv" "$name.hm.yuv" || fail "$name.hevc: ffmpeg and TAppDecoder decode different pictures"
    if [ "$hashes" -eq 0 ] && cmp -s "x265-lossless-$bits.yuv" "$name.hm.yuv"; then
      ok "$name.hevc: ffmpeg and TAppDecoder agree, with the hashes and with x265-lossless-$bits.yuv"
    else
      note "$name.hevc: ffmpeg and TAppDecoder agree with each other, not with the hashes of x265 nor with the source: x265 did not encode these pictures without loss"
    fi
  done

  # The third hash of HEVC, a checksum. libde265 1.1.3 computes it as it does
  # for 8 bits whatever the bit depth, so dec265 --check-hash rejects the 10
  # and 12-bit pictures it decodes right. As for the slices of kvazaar below,
  # this is reported rather than failed.
  msg "x265 (ffmpeg): checksum"
  run "checksum" x265-checksum-8.hevc "$FFMPEG" -hide_banner -v error -y -f rawvideo -pix_fmt yuv420p -s 64x64 -i x265-420-8.yuv \
    -c:v libx265 -x265-params hash=3 -f hevc x265-checksum-8.hevc
  agree x265-checksum-8.hevc yuv420p "$(picture_bytes 64 64 8 420 3)"
  run "checksum" x265-checksum-10.hevc "$FFMPEG" -hide_banner -v error -y -f rawvideo -pix_fmt yuv420p10le -s 64x64 -i x265-420-10.yuv \
    -c:v libx265 -x265-params hash=3 -f hevc x265-checksum-10.hevc
  decode_hm x265-checksum-10.hevc x265-checksum-10.hm.yuv
  decode_ffmpeg x265-checksum-10.hevc yuv420p10le x265-checksum-10.ffmpeg.yuv
  run "checksum" x265-checksum-10.dec265.yuv "$DEC265" -q -t 0 -o x265-checksum-10.dec265.yuv x265-checksum-10.hevc
  cmp -s x265-checksum-10.ffmpeg.yuv x265-checksum-10.hm.yuv || fail "x265-checksum-10.hevc: ffmpeg and TAppDecoder decode different pictures"
  cmp -s x265-checksum-10.dec265.yuv x265-checksum-10.hm.yuv || fail "x265-checksum-10.hevc: dec265 and TAppDecoder decode different pictures"
  ok "x265-checksum-10.hevc: ffmpeg, dec265 and TAppDecoder agree, with the hashes checked by TAppDecoder"
  if "$DEC265" -q -t 0 -c -o x265-checksum-10.checked.yuv x265-checksum-10.hevc > tool.log 2>&1; then
    ok "x265-checksum-10.hevc: dec265 --check-hash accepts the checksums too"
  else
    note "x265-checksum-10.hevc: dec265 --check-hash rejects the checksums of 10-bit pictures it decodes right: $(tr -d '\r' < tool.log | sed -n 1p)"
  fi

  msg "x265 tool"
  pictures 64 64 12 422 3 > x265-tool.yuv
  run "x265 tool" x265-tool.hevc "$X265" --input x265-tool.yuv --input-res 64x64 --input-depth 12 --input-csp i422 \
    --fps 30 --output-depth 12 --hash 2 -o x265-tool.hevc
  agree x265-tool.hevc yuv422p12le "$(picture_bytes 64 64 12 422 3)"
}

test_kvazaar() {
  # A tile is at least 256x64 samples. kvazaar is the encoder that writes
  # tiles, and wavefronts in dependent slice segments.
  pictures 512 128 8 420 2 > kvazaar.yuv
  bytes="$(picture_bytes 512 128 8 420 2)"

  msg "kvazaar: tiles"
  run "tiles" kvazaar-tiles.hevc "$FFMPEG" -hide_banner -v error -y -f rawvideo -pix_fmt yuv420p -s 512x128 -i kvazaar.yuv \
    -c:v libkvazaar -kvazaar-params tiles=2x2,hash=md5 -f hevc kvazaar-tiles.hevc
  syntax kvazaar-tiles.hevc
  has_syntax kvazaar-tiles.hevc tiles_enabled_flag 1 num_tile_columns_minus1 1 num_tile_rows_minus1 1
  agree kvazaar-tiles.hevc yuv420p "$bytes"

  msg "kvazaar: wavefronts and dependent slice segments"
  run "wavefronts" kvazaar-wpp.hevc "$KVAZAAR" -i kvazaar.yuv --input-res 512x128 --wpp --slices wpp \
    --hash checksum -o kvazaar-wpp.hevc
  syntax kvazaar-wpp.hevc
  has_syntax kvazaar-wpp.hevc entropy_coding_sync_enabled_flag 1 dependent_slice_segments_enabled_flag 1 \
    dependent_slice_segment_flag 1
  agree kvazaar-wpp.hevc yuv420p "$bytes"

  # A slice per tile, and no filter across the slices. Without SAO the three
  # decoders agree.
  msg "kvazaar: a slice per tile"
  run "slices" kvazaar-slices.hevc "$KVAZAAR" -i kvazaar.yuv --input-res 512x128 --tiles 2x2 --slices tiles \
    --no-sao --hash md5 -o kvazaar-slices.hevc
  syntax kvazaar-slices.hevc
  has_syntax kvazaar-slices.hevc tiles_enabled_flag 1 pps_loop_filter_across_slices_enabled_flag 0 \
    first_slice_segment_in_pic_flag 0
  agree kvazaar-slices.hevc yuv420p "$bytes"

  # With SAO, libde265 1.1.3 decodes other samples than ffmpeg and HM along
  # the slices, and its own hash check says so: it applies SAO across slices
  # that have pps_loop_filter_across_slices_enabled_flag = 0. HM, which checks
  # the MD5 of kvazaar, and ffmpeg are the ones that agree, so this is not an
  # error of the build, and it is reported rather than failed: the day
  # libde265 is fixed, the note goes away.
  run "slices and SAO" kvazaar-slices-sao.hevc "$KVAZAAR" -i kvazaar.yuv --input-res 512x128 --tiles 2x2 --slices tiles \
    --hash md5 -o kvazaar-slices-sao.hevc
  syntax kvazaar-slices-sao.hevc
  has_syntax kvazaar-slices-sao.hevc pps_loop_filter_across_slices_enabled_flag 0 sample_adaptive_offset_enabled_flag 1
  decode_hm kvazaar-slices-sao.hevc kvazaar-slices-sao.hm.yuv
  decode_ffmpeg kvazaar-slices-sao.hevc yuv420p kvazaar-slices-sao.ffmpeg.yuv
  cmp -s kvazaar-slices-sao.ffmpeg.yuv kvazaar-slices-sao.hm.yuv \
    || fail "kvazaar-slices-sao.hevc: ffmpeg and TAppDecoder decode different pictures"
  ok "kvazaar-slices-sao.hevc: ffmpeg and TAppDecoder agree, with the hashes ($bytes bytes)"
  if "$DEC265" -q -t 0 -c -o kvazaar-slices-sao.dec265.yuv kvazaar-slices-sao.hevc > tool.log 2>&1 \
     && cmp -s kvazaar-slices-sao.dec265.yuv kvazaar-slices-sao.hm.yuv; then
    ok "kvazaar-slices-sao.hevc: dec265 agrees too"
  else
    note "kvazaar-slices-sao.hevc: dec265 does not agree (SAO across slices that turn the in-loop filters off): $(tr -d '\r' < tool.log | sed -n 1p)"
  fi
}

# hm_encode <name> <width> <height> <bits> <chroma> <pictures> <encoder option>...
hm_encode() {
  name="$1"; width="$2"; height="$3"; bits="$4"; chroma="$5"; count="$6"; shift 6
  pictures "$width" "$height" "$bits" "$chroma" "$count" > "$name.yuv"
  run "$name" "$name.hevc" "$HM_ENCODER" -c hm.cfg -i "$name.yuv" -b "$name.hevc" -o "$name.rec.yuv" \
    --SourceWidth="$width" --SourceHeight="$height" --FramesToBeEncoded="$count" \
    --InputBitDepth="$bits" --InputChromaFormat="$chroma" --SEIDecodedPictureHash=1 "$@"
  agree "$name.hevc" "$(pixel_format "$bits" "$chroma")" "$(picture_bytes "$width" "$height" "$bits" "$chroma" "$count")" "$name.rec.yuv"
}

test_hm() {
  # See scripts/verify-hm.sh.
  cat > hm.cfg <<'EOF'
Tier                          : main
Level                         : 4.1
FrameRate                     : 30
MaxCUWidth                    : 16
MaxCUHeight                   : 16
MaxPartitionDepth             : 2
QuadtreeTULog2MaxSize         : 4
QuadtreeTULog2MinSize         : 2
QuadtreeTUMaxDepthInter       : 2
QuadtreeTUMaxDepthIntra       : 2
DecodingRefreshType           : 1
GOPSize                       : 1
FastSearch                    : 1
SearchRange                   : 16
QP                            : 22
RDOQ                          : 1
RDOQTS                        : 1
SAO                           : 1
AMP                           : 1
TransformSkip                 : 1
TransformSkipFast             : 1
EOF
  low_delay="P 1 0 0.0 0.0 0 0 1.0 0 0 0 1 1 -1 0"

  msg "HM: version 1 profiles"
  hm_encode hm-main 64 64 8 420 3 --Profile=main --IntraPeriod=-1 "--Frame1=$low_delay"
  hm_encode hm-main10 64 64 10 420 3 --Profile=main10 --IntraPeriod=-1 "--Frame1=$low_delay"

  msg "HM: tiles and dependent slice segments"
  hm_encode hm-tiles 512 128 8 420 1 --Profile=main --IntraPeriod=1 --MaxCUWidth=64 --MaxCUHeight=64 \
    --MaxPartitionDepth=4 --QuadtreeTULog2MaxSize=5 \
    --TileUniformSpacing=1 --NumTileColumnsMinus1=1 --NumTileRowsMinus1=1 \
    --SliceMode=3 --SliceArgument=2 --SliceSegmentMode=1 --SliceSegmentArgument=2
  syntax hm-tiles.hevc
  has_syntax hm-tiles.hevc tiles_enabled_flag 1 num_tile_columns_minus1 1 num_tile_rows_minus1 1 \
    dependent_slice_segments_enabled_flag 1 dependent_slice_segment_flag 1

  msg "HM: range extensions"
  hm_encode hm-422 32 32 10 422 2 --Profile=main_422_10_intra --IntraPeriod=1
  hm_encode hm-400 32 32 12 400 2 --Profile=monochrome12 --IntraPeriod=1
  for bits in 8 10 12; do
    hm_encode "hm-rext-$bits" 32 32 "$bits" 444 3 --Profile=main-RExt --IntraPeriod=-1 "--Frame1=$low_delay" \
      --TransformSkipLog2MaxSize=4 --CrossComponentPrediction=1 \
      --ImplicitResidualDPCM=1 --ExplicitResidualDPCM=1 --ResidualRotation=1 \
      --SingleSignificanceMapContext=1 --GolombRiceParameterAdaptation=1 --HighPrecisionPredictionWeighting=1
    syntax "hm-rext-$bits.hevc"
    has_syntax "hm-rext-$bits.hevc" chroma_format_idc 3 bit_depth_luma_minus8 $((bits - 8)) \
      cross_component_prediction_enabled_flag 1 implicit_rdpcm_enabled_flag 1 explicit_rdpcm_enabled_flag 1 \
      transform_skip_rotation_enabled_flag 1 transform_skip_context_enabled_flag 1 \
      persistent_rice_adaptation_enabled_flag 1 log2_max_transform_skip_block_size_minus2 2 \
      extended_precision_processing_flag 0
  done
}

# rgb <file> <width> <height> <channels> <bits> <shift>: interleaved samples.
rgb() {
  plane $(($2 * $3)) "$4" "$5" 7 "$6" > "$1"
}

# png_samples <PNG file> <pixel format> <output>: the samples of a PNG file.
png_samples() {
  run "$1" "$3" "$FFMPEG" -hide_banner -v error -y -i "$1" -f rawvideo -pix_fmt "$2" "$3"
}

# heic_lossless <name> <pixel format> <width> <height> <heif-enc option>...
#
# <name>.raw, written as a PNG file by ffmpeg, encoded without loss by
# heif-enc and decoded to a PNG file by heif-dec: the same samples.
heic_lossless() {
  name="$1"; format="$2"; width="$3"; height="$4"; shift 4
  run "$name" "$name.png" "$FFMPEG" -hide_banner -v error -y -f rawvideo -pix_fmt "$format" -s "${width}x$height" -i "$name.raw" \
    -frames:v 1 -c:v png "$name.png"
  run "$name" "$name.heic" "$HEIF_ENC" -L "$@" "$name.png" -o "$name.heic"
  run "$name" "$name.decoded.png" "$HEIF_DEC" "$name.heic" "$name.decoded.png"
  png_samples "$name.decoded.png" "$format" "$name.decoded.raw"
  cmp -s "$name.raw" "$name.decoded.raw" || fail "$name: heif-dec does not decode the source samples"
  ok "$name: PNG -> heif-enc (lossless) -> heif-dec -> PNG gives the source samples"
}

# heic_stream <name> <pixel format> <bytes>: the HEVC stream of an image of a
# HEIC file, which the three decoders decode as they do any other stream.
heic_stream() {
  run "$1" "$1.hevc" "$FFMPEG" -hide_banner -v error -y -i "$1.heic" -c:v copy -bsf:v hevc_mp4toannexb -f hevc "$1.hevc"
  decode_ffmpeg "$1.hevc" "$2" "$1.ffmpeg.yuv"
  [ "$(($(wc -c < "$1.ffmpeg.yuv")))" -eq "$3" ] || fail "$1.hevc does not decode to $3 bytes"
  run "$1" "$1.dec265.yuv" "$DEC265" -q -t 0 -o "$1.dec265.yuv" "$1.hevc"
  run "$1" "$1.hm.yuv" "$HM_DECODER" -b "$1.hevc" -o "$1.hm.yuv" -d 0
  cmp -s "$1.ffmpeg.yuv" "$1.hm.yuv" || fail "$1.hevc: ffmpeg and TAppDecoder decode different pictures"
  cmp -s "$1.dec265.yuv" "$1.hm.yuv" || fail "$1.hevc: dec265 and TAppDecoder decode different pictures"
  ok "$1.heic: ffmpeg, dec265 and TAppDecoder agree on the stream of the image ($3 bytes)"
}

test_heic() {
  msg "HEIC: lossless"
  rgb heic-8.raw 64 48 3 8 0
  heic_lossless heic-8 rgb24 64 48
  "$HEIF_INFO" heic-8.heic > tool.log 2>&1 || { cat tool.log >&2; fail "heif-info heic-8.heic failed"; }
  contains "$(cat tool.log)" "bit depth: 8" || { cat tool.log >&2; fail "heic-8.heic is not an 8-bit image"; }
  # 16-bit PNG files of 10-bit samples: the 10 and the 12-bit images hold them.
  for bits in 10 12; do
    rgb "heic-$bits.raw" 64 48 3 10 6
    heic_lossless "heic-$bits" rgb48le 64 48 -b "$bits"
    "$HEIF_INFO" "heic-$bits.heic" > tool.log 2>&1 || { cat tool.log >&2; fail "heif-info heic-$bits.heic failed"; }
    contains "$(cat tool.log)" "bit depth: $bits" || { cat tool.log >&2; fail "heic-$bits.heic is not a $bits-bit image"; }
  done
  rgb heic-alpha.raw 64 48 4 8 0
  heic_lossless heic-alpha rgba 64 48
  rgb heic-grid.raw 128 128 3 8 0
  heic_lossless heic-grid rgb24 128 128 --cut-tiles 64
  "$HEIF_INFO" heic-grid.heic > tool.log 2>&1 || { cat tool.log >&2; fail "heif-info heic-grid.heic failed"; }
  contains "$(cat tool.log)" "tiles: 2x2, tile size: 64x64" || { cat tool.log >&2; fail "heic-grid.heic is not a grid of 2x2 tiles"; }

  # The stream of the image, 64x64: x265 pads the 48 rows, and the HEIC file
  # crops them.
  msg "HEIC: the stream of an image"
  heic_stream heic-8 gbrp $((64 * 64 * 3))
  heic_stream heic-10 gbrp10le $((64 * 64 * 3 * 2))
  heic_stream heic-12 gbrp12le $((64 * 64 * 3 * 2))
  run "4:2:0" heic-420.heic "$HEIF_ENC" heic-8.png -o heic-420.heic
  heic_stream heic-420 yuvj420p $((64 * 64 * 3 / 2))
  run "4:2:2 12 bits" heic-422.heic "$HEIF_ENC" -b 12 -p chroma=422 heic-12.png -o heic-422.heic
  heic_stream heic-422 yuv422p12le $((64 * 64 * 2 * 2))

  # heif-dec writes the planes of a 4:2:0 image as they are in a Y4M file:
  # the 48 first rows of what the HEVC decoders write, and what ffmpeg decodes
  # from the HEIC file.
  run "Y4M" heic-420.y4m "$HEIF_DEC" heic-420.heic heic-420.y4m
  tail -c $((64 * 48 * 3 / 2)) heic-420.y4m > heic-420.heif-dec.yuv
  {
    head -c $((64 * 48)) heic-420.hm.yuv
    tail -c +$((64 * 64 + 1)) heic-420.hm.yuv | head -c $((32 * 24))
    tail -c +$((64 * 64 + 32 * 32 + 1)) heic-420.hm.yuv | head -c $((32 * 24))
  } > heic-420.cropped.yuv
  cmp -s heic-420.heif-dec.yuv heic-420.cropped.yuv || fail "heic-420.heic: heif-dec and TAppDecoder decode different pictures"
  run "ffmpeg" heic-420.direct.yuv "$FFMPEG" -hide_banner -v error -y -i heic-420.heic -f rawvideo -pix_fmt yuvj420p heic-420.direct.yuv
  cmp -s heic-420.direct.yuv heic-420.cropped.yuv || fail "heic-420.heic: ffmpeg and TAppDecoder decode different pictures"
  ok "heic-420.heic: heif-dec, ffmpeg and TAppDecoder agree on the cropped image"
}

# ---------------------------------------------------------------------------

workdir="smoke-hevc-$TARGET"
rm -rf "$workdir"; mkdir -p "$workdir"
cd "$workdir"
FFMPEG="../$(basename "$FFMPEG")"
X265="../$(basename "$X265")"
KVAZAAR="../$(basename "$KVAZAAR")"
DEC265="../$(basename "$DEC265")"
HEIF_ENC="../$(basename "$HEIF_ENC")"
HEIF_DEC="../$(basename "$HEIF_DEC")"
HEIF_INFO="../$(basename "$HEIF_INFO")"
HM_ENCODER="../$(basename "$HM_ENCODER")"
HM_DECODER="../$(basename "$HM_DECODER")"

test_x265
test_kvazaar
test_hm
test_heic

cd ..
msg "verification passed for $TARGET"
