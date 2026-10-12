#!/usr/bin/env bash
#
# Verifies the TAppEncoder/TAppDecoder pair built by scripts/build-hm.sh.
#
#   bash scripts/verify-hm.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertions plus real encode+decode round-trips (must run on
#         the target platform)
#   all   both (default)
#
# The round-trips cover what HM is published for: the range extensions (4:2:2,
# 4:4:4 and monochrome, 10, 12 and 16 bits, cross-component prediction, RDPCM,
# the transform-skip extensions, the persistent Rice adaptation, the extended
# precision), tiles and dependent slice segments. Each stream is decoded by
# TAppDecoder, which checks the picture hashes the encoder wrote, and the
# decoded pictures are compared with the reconstruction of the encoder.
# scripts/verify-hevc.sh compares TAppDecoder with ffmpeg and dec265.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64) EXE=""; PLATFORM="Linux" ;;
  osx-arm64) EXE=""; PLATFORM="Mac OS X" ;;
  win-x64) EXE=".exe"; PLATFORM="Windows" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

HM_ENCODER="./TAppEncoder-$TARGET$EXE"
HM_DECODER="./TAppDecoder-$TARGET$EXE"
for bin in "$HM_ENCODER" "$HM_DECODER"; do
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

# No `echo ... | grep -q` in this script: grep closes the pipe early, the
# writer takes SIGPIPE, and `set -o pipefail` turns that into a spurious failure.
contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Linkage
# ---------------------------------------------------------------------------

# The llvm-mingw objdump comes first: the Windows binaries are checked on the
# Linux machine that cross-compiles them.
find_objdump() {
  for candidate in x86_64-w64-mingw32-objdump objdump llvm-objdump; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

assert_linkage() {
  bin="$1"
  case "$TARGET" in
    linux-*)
      description="$(file "$bin")"
      contains "$description" 'statically linked' || contains "$description" 'static-pie linked' \
        || fail "$bin is not statically linked: $description"
      # ldd exits non-zero on a static binary, hence no `set -e` trip here.
      if ldd "$bin" 2>/dev/null | grep -q '=>'; then
        fail "$bin has dynamic dependencies: $(ldd "$bin" 2>/dev/null)"
      fi
      ok "$bin is fully static"
      ;;
    osx-arm64)
      # macOS has no static libSystem; assert only system dylibs are referenced.
      deps="$(otool -L "$bin" | tail -n +2 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*(.*$//' \
              | grep -v '^/usr/lib/' | grep -v '^/System/Library/' || true)"
      [ -z "$deps" ] || fail "$bin links non-system dylibs: $deps"
      ok "$bin links only system dylibs"
      ;;
    win-*)
      objdump="$(find_objdump)" || fail "no objdump or llvm-objdump to list the imports of $bin"
      imports="$("$objdump" -p "$bin" | sed -n 's/^[[:space:]]*DLL Name: //p' \
                 | tr 'A-Z' 'a-z' | tr -d '\r' | sort -u)"
      [ -n "$imports" ] || fail "could not list the imports of $bin"
      bad=""
      for dll in $imports; do
        # DLLs that ship with Windows itself; ucrtbase and the api-ms-win-crt-*
        # stubs are the UCRT, a Windows component since Windows 10. Anything
        # else means a dependency leaked in dynamically -- most likely
        # libc++.dll, libunwind.dll, libwinpthread-1.dll or libomp.dll.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|advapi32.dll|shell32.dll|ucrtbase.dll|api-ms-win-*) ;;
          *) bad="$bad $dll" ;;
        esac
      done
      [ -z "$bad" ] || fail "$bin imports non-system DLLs:$bad"
      ok "$bin imports only system DLLs ($(echo $imports | tr ' ' ','))"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

# HM has no --version. Without an argument, the tools print their banner and
# their options, and fail, for instance:
#   HM software: Encoder Version [18.0] (including RExt)[Linux][GCC 4.2.1][64 bit]
# "GCC 4.2.1" is what clang reports as its GCC version.
assert_version() {
  tool="$1"; bin="$2"; kind="$3"; option="$4"
  status=0
  output="$("$bin" 2>&1 | tr -d '\r')" || status=$?
  [ "$status" -eq 1 ] || fail "$tool without an argument exited with $status instead of 1"
  contains "$output" "HM software: $kind Version [" || { echo "$output" >&2; fail "$tool does not print its banner"; }
  if [ -n "$HM_VERSION" ]; then
    contains "$output" "HM software: $kind Version [$HM_VERSION] (including RExt)" \
      || fail "$tool does not report version $HM_VERSION"
    ok "$tool reports version $HM_VERSION"
  else
    echo "  HM_VERSION is not set; skipping the $tool version check"
  fi
  contains "$output" "[$PLATFORM]" || fail "$tool was not built for $PLATFORM"
  contains "$output" "[64 bit]" || fail "$tool is not a 64-bit build"
  contains "$output" "$option" || fail "$tool does not list its options ($option)"
  ok "$tool is a 64-bit $PLATFORM build"
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# plane <width> <height> <bits> <seed>: the samples of a plane, one byte each
# up to 8 bits and two bytes, little endian, above. The rows are four ramps
# that depend on the seed, repeated.
plane() {
  plane_width="$1"; plane_height="$2"; plane_bits="$3"; plane_seed="$4"
  modulus=$((1 << plane_bits))
  r=0
  while [ "$r" -lt 4 ]; do
    row=""
    x=0
    while [ "$x" -lt "$plane_width" ]; do
      value=$(((x * 37 + r * 101 + plane_seed * 59) * 13 % modulus))
      if [ "$plane_bits" -gt 8 ]; then
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

# count_of <text> <file>: the number of lines of the file that have the text.
count_of() {
  grep -c -F -- "$1" "$2" || true
}

# round_trip <name> <width> <height> <bits> <chroma> <pictures> <encoder option>...
#
# Encodes the pictures with a hash of every decoded picture (an MD5 per
# plane), decodes the stream, and checks that the decoder
# - accepts every hash,
# - writes the pictures the encoder reconstructed, in the bit depth of the
#   stream (-d 0).
round_trip() {
  name="$1"; width="$2"; height="$3"; bits="$4"; chroma="$5"; count="$6"; shift 6
  pictures "$width" "$height" "$bits" "$chroma" "$count" > "$name.yuv"
  expected="$(picture_bytes "$width" "$height" "$bits" "$chroma" "$count")"
  [ "$(($(wc -c < "$name.yuv")))" -eq "$expected" ] || fail "$name.yuv was not written correctly"

  rm -f "$name.bin" "$name.rec.yuv" "$name.dec.yuv"
  "$HM_ENCODER" -c common.cfg -i "$name.yuv" -b "$name.bin" -o "$name.rec.yuv" \
    --SourceWidth="$width" --SourceHeight="$height" --FramesToBeEncoded="$count" \
    --InputBitDepth="$bits" --InputChromaFormat="$chroma" --SEIDecodedPictureHash=1 "$@" \
    > "$name.enc.log" 2>&1 || { cat "$name.enc.log" >&2; fail "$name: TAppEncoder failed"; }
  [ -s "$name.bin" ] || { cat "$name.enc.log" >&2; fail "$name: TAppEncoder wrote no stream"; }
  [ "$(($(wc -c < "$name.rec.yuv")))" -eq "$expected" ] || fail "$name: the reconstruction is not $expected bytes"

  "$HM_DECODER" -b "$name.bin" -o "$name.dec.yuv" -d 0 > "$name.dec.log" 2>&1 \
    || { cat "$name.dec.log" >&2; fail "$name: TAppDecoder failed"; }
  [ "$(count_of ',(OK)]' "$name.dec.log")" -eq "$count" ] \
    || { cat "$name.dec.log" >&2; fail "$name: TAppDecoder did not check the hash of $count pictures"; }
  [ "$(count_of 'ERROR' "$name.dec.log")" -eq 0 ] || { cat "$name.dec.log" >&2; fail "$name: TAppDecoder reports an error"; }
  cmp -s "$name.rec.yuv" "$name.dec.yuv" \
    || fail "$name: the decoded pictures differ from the reconstruction of the encoder"
  ok "$name: ${width}x$height $chroma $bits-bit, $count pictures, $(($(wc -c < "$name.bin"))) bytes, hashes and reconstruction match"
}

# encoder_reports <name> <text>...: every text is in the log of the encoder.
encoder_reports() {
  name="$1"; shift
  log="$(tr -d '\r' < "$name.enc.log")"
  for text in "$@"; do
    contains "$log" "$text" || { echo "$log" >&2; fail "$name: TAppEncoder does not report '$text'"; }
  done
}

smoke_test() {
  workdir="smoke-hm-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  HM_ENCODER="../$(basename "$HM_ENCODER")"
  HM_DECODER="../$(basename "$HM_DECODER")"

  # What every stream has in common. HM publishes configuration files for the
  # common test conditions; they are made for large pictures, and the encoder
  # takes any parameter from the file or from the command line.
  cat > common.cfg <<'EOF'
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
  # One reference picture, the previous one: P pictures after the first one.
  low_delay="P 1 0 0.0 0.0 0 0 1.0 0 0 0 1 1 -1 0"

  msg "version 1 profiles"
  round_trip main 64 64 8 420 3 --Profile=main --IntraPeriod=-1 "--Frame1=$low_delay"
  encoder_reports main "Profile                                : main" "RExt__HIGH_BIT_DEPTH_SUPPORT =   1" \
    "implicit_rdpcm_enabled_flag            : Disabled" "cross_component_prediction_enabled_flag: Disabled"
  [ "$(count_of 'P-SLICE' main.dec.log)" -eq 2 ] || fail "main: the stream does not have 2 P pictures"
  ok "main: 1 I picture and 2 P pictures"
  round_trip main10 16 16 10 420 2 --Profile=main10 --IntraPeriod=1

  # A tile is at least 256x64 samples.
  msg "tiles and dependent slice segments"
  round_trip tiles 512 128 8 420 1 --Profile=main --IntraPeriod=1 --MaxCUWidth=64 --MaxCUHeight=64 \
    --MaxPartitionDepth=4 --QuadtreeTULog2MaxSize=5 \
    --TileUniformSpacing=1 --NumTileColumnsMinus1=1 --NumTileRowsMinus1=1 \
    --SliceMode=3 --SliceArgument=2 --SliceSegmentMode=1 --SliceSegmentArgument=2
  # The log of the encoder does not have the tiles; scripts/verify-hevc.sh
  # reads them in the stream.
  encoder_reports tiles "Slice: M=3 A=2 SliceSegment: M=1 A=2"

  msg "range extensions"
  round_trip intra422 16 16 10 422 2 --Profile=main_422_10_intra --IntraPeriod=1
  encoder_reports intra422 "(main_422_10_intra)" "Input ChromaFormatIDC =   4:2:2"
  round_trip mono12 16 16 12 400 2 --Profile=monochrome12 --IntraPeriod=1
  round_trip rext444 32 32 12 444 3 --Profile=main-RExt --IntraPeriod=-1 "--Frame1=$low_delay" \
    --TransformSkipLog2MaxSize=4 --CrossComponentPrediction=1 \
    --ImplicitResidualDPCM=1 --ExplicitResidualDPCM=1 --ResidualRotation=1 \
    --SingleSignificanceMapContext=1 --GolombRiceParameterAdaptation=1 --HighPrecisionPredictionWeighting=1
  encoder_reports rext444 "(main_444_12)" "Input ChromaFormatIDC =   4:4:4" \
    "implicit_rdpcm_enabled_flag            : Enabled" \
    "explicit_rdpcm_enabled_flag            : Enabled" \
    "transform_skip_rotation_enabled_flag   : Enabled" \
    "transform_skip_context_enabled_flag    : Enabled" \
    "cross_component_prediction_enabled_flag: Enabled" \
    "high_precision_offsets_enabled_flag    : Enabled" \
    "persistent_rice_adaptation_enabled_flag: Enabled" \
    "TransformSkipLog2MaxSize:4"

  # 16 bits and the extended precision are what HIGH_BITDEPTH is for: a default
  # build of HM stops at 12 bits.
  msg "high bit depth"
  round_trip extended16 16 16 16 444 1 --Profile=main_444_16_intra --IntraPeriod=1 --ExtendedPrecision=1
  encoder_reports extended16 "(main_444_16_intra)" "Internal bit depth                     : (Y:16, C:16)" \
    "extended_precision_processing_flag     : Enabled"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$HM_ENCODER"
    assert_linkage "$HM_DECODER"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    assert_version TAppEncoder "$HM_ENCODER" Encoder "--SEIDecodedPictureHash"
    assert_version TAppDecoder "$HM_DECODER" Decoder "--SEIDecodedPictureHash"
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
