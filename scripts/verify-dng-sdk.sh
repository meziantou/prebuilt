#!/usr/bin/env bash
#
# Verifies dng_validate, the tool of the Adobe DNG SDK built by
# scripts/build-dng-sdk.sh.
#
#   bash scripts/verify-dng-sdk.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage and version assertions only
#   run   version assertion plus the tests below (must run on the target)
#   all   both (default)
#
# The tests use the DNG file of scripts/dng-samples.sh (32 x 32 12-bit
# samples, an RGGB color filter array, DNG 1.4):
# - dng_validate validates it (exit code 0, "Validation complete"), with
#   warnings about the padding of so small a CFA image, and -v prints its
#   tags;
# - -1 writes the stage 1 image, the CFA samples as stored, to a TIFF file;
#   -3 the stage 3 image (demosaiced, linear), and -tif the rendered image
#   (sRGB, 8 bits, or 16 bits with -16);
# - -dng with -losslessJXL writes a DNG 1.7 file with JPEG XL compression,
#   which dng_validate validates, and which gives the same stage 1 image back;
# - a file that is not a DNG file fails, with the exit code of the DNG SDK
#   error less 100000, plus 100 (111: end of file).
# The stage images are pinned, the same on every runtime identifier. The
# -tif and -dng files have the time they were written (DateTime,
# xmp:ModifyDate): they are not pinned.
#
# DNG_SDK_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
[ -n "$DNG_SDK_VERSION" ] || { echo "DNG_SDK_VERSION is not set" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

BIN="./dng_validate-$TARGET$EXE"
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
# shellcheck source=dng-samples.sh
. "$SCRIPT_DIR/dng-samples.sh"

# validate <label> <options and file...>: dng_validate succeeds; its output is
# in validate.log.
validate() {
  validate_label="$1"; shift
  "$D" "$@" > validate.log 2>&1 || { cat validate.log >&2; fail "$validate_label: dng_validate $* failed"; }
}

tests() {
  workdir="smoke-dng-sdk-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  D="../dng_validate-$TARGET$EXE"
  write_test_dng .

  msg "validation"
  validate "validation" test.dng
  log="$(tr -d '\r' < validate.log)"
  contains "$log" 'Validating "test.dng"...' || fail "dng_validate: $log"
  contains "$log" "Validation complete" || fail "dng_validate: $log"
  contains "$log" "Too little padding on left edge of CFA image" || fail "dng_validate: $log"
  ok "test.dng is valid (with warnings about the padding of the CFA image)"
  validate "verbose" -v test.dng
  log="$(tr -d '\r' < validate.log)"
  for text in "DNGVersion: 1.4.0.0" "UniqueCameraModel: \"Prebuilt Test\"" "CFAPattern:" "WhiteLevel: 4095" "CalibrationIlluminant1: D65"; do
    contains "$log" "$text" || fail "dng_validate -v has no '$text'"
    ok "dng_validate -v: $text"
  done

  msg "rendering"
  validate "stages" -1 stage1 -3 stage3 -tif render test.dng
  # The stage 1 image: the CFA samples, little-endian, after the TIFF header
  # and tags (146 bytes).
  tail -c +147 stage1.tif | head -c 2048 > stage1-samples.raw
  same_file "stage 1: the CFA samples, as stored" stage1-samples.raw cfa.raw
  expect "stage 1" "$(sha256_of stage1.tif)" "$PIN_STAGE1"
  expect "stage 3 (demosaiced, linear)" "$(sha256_of stage3.tif)" "$PIN_STAGE3"
  expect "-tif: a TIFF file" "$(hex_of_n render.tif 4)" "49492a00"
  validate "16 bits" -16 -tif render16 test.dng
  [ "$(file_size render16.tif)" -gt "$(file_size render.tif)" ] || fail "-16 does not write a larger TIFF file"
  ok "-16: a 16-bit TIFF file"

  msg "JPEG XL"
  validate "lossless JPEG XL" -losslessJXL -dng jxl test.dng
  validate "validation of the JPEG XL DNG file" -v jxl.dng
  log="$(tr -d '\r' < validate.log)"
  for text in "DNGVersion: 1.7.1.0" "Compression: JXL" "JXLDistance: 0.00"; do
    contains "$log" "$text" || fail "dng_validate -v jxl.dng has no '$text'"
    ok "the DNG file -losslessJXL writes: $text"
  done
  validate "stage 1 of the JPEG XL DNG file" -1 stage1-jxl jxl.dng
  same_file "lossless JPEG XL gives the same stage 1 image" stage1-jxl.tif stage1.tif

  msg "invalid files"
  printf 'II*\000garbage' > invalid.dng
  status=0; "$D" invalid.dng > validate.log 2>&1 || status=$?
  expect "a file that is not a DNG file: exit code 111 (end of file)" "$status" "111"

  cd ..
  ok "all tests passed"
}

PIN_STAGE1="9702397477924d268db985887f12549131dd3bc7e0ac87dbe516983035a919c2"
PIN_STAGE3="d77b5df7b25f3912ca0c5c68b073f7c1b004555a2498dcebd785ec51cdfc142d"

case "$MODE" in
  link|all)
    msg "linkage and version ($TARGET)"
    assert_linkage "$BIN"
    grep -a -q -F "$DNG_SDK_VERSION" "$BIN" || fail "$BIN does not contain '$DNG_SDK_VERSION'"
    ok "$BIN contains $DNG_SDK_VERSION"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    banner="$("$BIN" 2>&1 | tr -d '\r' | sed -n 2p || true)"
    expect "dng_validate" "$banner" "dng_validate, version $DNG_SDK_VERSION (64-bit)"
    tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
