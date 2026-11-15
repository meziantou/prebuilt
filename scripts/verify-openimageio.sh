#!/usr/bin/env bash
#
# Verifies oiiotool and iinfo, built by scripts/build-openimageio.sh.
#
#   bash scripts/verify-openimageio.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage and version assertions only
#   run   version assertion plus the tests below (must run on the target)
#   all   both (default)
#
# The pixels are compared as `oiiotool -v --info --dumpdata` prints them.
# The tests:
# - the formats: PSD, DPX, Cineon, DDS, HDR, TIFF, PNG, OpenEXR, raw (LibRaw)
#   and the others are read, DPX, HDR, TIFF, PNG and OpenEXR are written;
# - PSD and PSB files written byte by byte (scripts/psd-samples.sh): RGB 8-bit
#   and grayscale 32-bit (floats), raw samples;
# - DDS files written byte by byte: uncompressed RGBA, and BC1 (a block of
#   one 565 color, which decodes exactly);
# - DPX (10 bits, written little-endian, read back scaled to 16 bits), HDR,
#   TIFF (16 bits), PNG (16 bits) and OpenEXR (half): oiiotool writes them and
#   reads them back;
# - the DNG file of scripts/dng-samples.sh through LibRaw: its size, and its
#   CFA samples, as stored, with raw:Demosaic none.
# They assert that the PNM writer writes the rows bottom-up (the reader reads
# them top-down): compare pixels through TIFF, or --dumpdata.
#
# Also found out with the files of psd-tools write (not tested here): the PSD
# reader converts every color mode to RGB (or gray), and reads the raw and RLE
# compressions only; a ZIP or ZIP with prediction composite or layer fails the
# file ("unsupported compression").
#
# OPENIMAGEIO_VERSION and LIBRAW_VERSION come from the environment (see
# .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
for name in OPENIMAGEIO_VERSION LIBRAW_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

TOOLS="oiiotool iinfo"
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

# shellcheck source=psd-samples.sh
. "$SCRIPT_DIR/psd-samples.sh"
# shellcheck source=verify-common.sh
. "$SCRIPT_DIR/verify-common.sh"
# shellcheck source=dng-samples.sh
. "$SCRIPT_DIR/dng-samples.sh"

# pixels [oiiotool options...] <file>: the values of the pixels, as oiiotool
# prints them (integers for integer formats), one pixel per '|'.
pixels() {
  "$O" -v --info --dumpdata "$@" 2> oiio.err | tr -d '\r' | sed -n 's/^ *Pixel ([0-9]*, [0-9]*): \([^(]*\).*/\1/p' \
    | sed 's/ *$//' | tr '\n' '|' || { cat oiio.err >&2; fail "oiiotool $* failed"; }
}

# planar_be <file> <values...>: 8-bit samples, interleaved RGB in the
# arguments, written as 3 planes (the composite of a raw PSD file).
planes_of_rgb8() {
  planes_file="$1"; shift
  r=""; g=""; b=""
  while [ $# -ge 3 ]; do r="$r $1"; g="$g $2"; b="$b $3"; shift 3; done
  # shellcheck disable=SC2086
  write_bytes "$planes_file" $r $g $b
}

tests() {
  workdir="smoke-openimageio-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  O="../oiiotool-$TARGET$EXE"
  I="../iinfo-$TARGET$EXE"
  write_samples .

  msg "PSD"
  # shellcheck disable=SC2086
  planes_of_rgb8 rgb8-planes.raw $SAMPLE_RGB8
  write_flat_psd rgb8.psd 1 3 8 3 rgb8-planes.raw
  expect "an RGB 8-bit PSD file" "$("$I" rgb8.psd | tr -d '\r' | sed 's/ \{2,\}/ /g')" "rgb8.psd : 4 x 2, 3 channel, uint8 psd"
  expect "its pixels" "$(pixels rgb8.psd)" "255 0 0|0 255 0|0 0 255|128 128 128|0 0 0|255 255 255|16 32 48|192 176 160|"
  write_flat_psd rgb8.psb 2 3 8 3 rgb8-planes.raw
  expect "the same pixels from a PSB file" "$(pixels rgb8.psb)" "$(pixels rgb8.psd)"
  od -An -v -tu1 gray32.raw | tr -s ' \n\r' '   ' > gray32.txt
  set -- $(cat gray32.txt)
  be=""
  while [ $# -ge 4 ]; do be="$be $4 $3 $2 $1"; shift 4; done
  # shellcheck disable=SC2086
  write_bytes gray32-be.raw $be
  write_flat_psd gray32.psd 1 1 32 1 gray32-be.raw
  expect "a grayscale 32-bit PSD file: floats" "$(pixels gray32.psd)" \
    "0.000000000|1.000000000|0.500000000|0.250000000|2.000000000|0.125000000|0.062500000|0.750000000|"

  msg "DDS"
  # DDS header: "DDS ", size 124, flags (caps, height, width, pixel format),
  # height, width, pitch, depth, mip count 1, reserved; then the pixel format
  # (32 bytes), the caps (texture), and reserved fields.
  # dds_header <width> <height> <flags>
  dds_header() {
    printf 'DDS '
    printf "$(le32 124)$(le32 "$3")$(le32 "$2")$(le32 "$1")$(le32 0)$(le32 0)$(le32 1)"
    i=0; while [ "$i" -lt 11 ]; do printf "$(le32 0)"; i=$((i + 1)); done
  }
  # Uncompressed 4 x 2 RGBA: masks R 0x000000FF, G 0x0000FF00, B 0x00FF0000, A 0xFF000000.
  {
    dds_header 4 2 4111
    printf '\040\000\000\000\101\000\000\000\000\000\000\000\040\000\000\000'
    printf '\377\000\000\000\000\377\000\000\000\000\377\000\000\000\000\377'
    printf '\000\020\000\000'
    i=0; while [ "$i" -lt 16 ]; do printf '\000'; i=$((i + 1)); done
    cat rgba8.raw
  } > rgba.dds
  expect "an uncompressed RGBA DDS file" "$(pixels rgba.dds)" \
    "255 0 0 255|0 255 0 128|0 0 255 0|128 128 128 64|0 0 0 255|255 255 255 32|16 32 48 200|192 176 160 1|"
  # BC1 (DXT1) 4 x 4: color0 0xF800 (red), color1 0, every index 0.
  {
    dds_header 4 4 4103
    printf '\040\000\000\000\004\000\000\000DXT1'
    i=0; while [ "$i" -lt 20 ]; do printf '\000'; i=$((i + 1)); done
    printf '\000\020\000\000'
    i=0; while [ "$i" -lt 16 ]; do printf '\000'; i=$((i + 1)); done
    printf '\000\370\000\000\000\000\000\000'
  } > bc1.dds
  bc1="$(pixels bc1.dds)"
  expect "a BC1 DDS file: a 565 red block decodes to 255 0 0" "${bc1%%|*}" "255 0 0 255"

  msg "DPX, HDR, TIFF, PNG, OpenEXR"
  "$O" rgb8.psd -d uint10 -o rgb10.dpx 2> oiio.err || { cat oiio.err >&2; fail "oiiotool -o .dpx failed"; }
  # A little-endian DPX file (XPDS), whose 10-bit codes (v * 1023 / 255) are
  # read back scaled to 16 bits (c * 65535 / 1023): 514 is 32928.
  expect "DPX: a little-endian file (XPDS)" "$(od -An -c -N 4 rgb10.dpx | tr -d ' ')" "XPDS"
  expect "DPX: 10-bit samples, read back as 16 bits" "$(pixels rgb10.dpx)" \
    "65535 0 0|0 65535 0|0 0 65535|32928 32928 32928|0 0 0|65535 65535 65535|4100 8200 12300|49392 45228 41128|"
  "$O" gray32.psd --ch 0,0,0 -o gray.hdr 2> oiio.err || { cat oiio.err >&2; fail "oiiotool -o .hdr failed"; }
  expect "HDR: the radiance header" "$(head -c 10 gray.hdr)" "#?RADIANCE"
  expect "HDR: powers of 2 come back" "$(pixels gray.hdr | cut -d '|' -f 2,3,5)" \
    "1.000000000 1.000000000 1.000000000|0.500000000 0.500000000 0.500000000|2.000000000 2.000000000 2.000000000"
  for format in tif png; do
    "$O" rgb8.psd -d uint16 -o "rgb16.$format" 2> oiio.err || { cat oiio.err >&2; fail "oiiotool -o .$format failed"; }
    expect "$format: 16-bit samples (v * 257)" "$(pixels "rgb16.$format" | cut -d '|' -f 1-4)" "65535 0 0|0 65535 0|0 0 65535|32896 32896 32896"
  done
  "$O" gray32.psd -d half -o gray.exr 2> oiio.err || { cat oiio.err >&2; fail "oiiotool -o .exr failed"; }
  expect "OpenEXR: half floats" "$(pixels gray.exr | cut -d '|' -f 1-5)" "0.000000000|1.000000000|0.500000000|0.250000000|2.000000000"

  msg "camera raw (LibRaw)"
  write_test_dng .
  expect "iinfo of the DNG file" "$("$I" test.dng | tr -d '\r' | sed 's/ \{2,\}/ /g')" "test.dng : 32 x 32, 3 channel, uint16 raw"
  cfa="$(pixels -iconfig raw:Demosaic none test.dng | tr '|' ' ')"
  expected="$(od -An -v -tu2 cfa.raw | tr -s ' \n\r' '   ' | sed 's/^ //;s/ $//')"
  expect "raw:Demosaic none: the CFA samples, as stored" "$(echo $cfa)" "$(echo $expected)"

  msg "what OpenImageIO does not do"
  printf 'P5\n2 3\n255\n\001\002\003\004\005\006' > rows.pgm
  "$O" rows.pgm -o rows-again.pgm 2> oiio.err || { cat oiio.err >&2; fail "oiiotool -o .pgm failed"; }
  expect "the PNM writer writes the rows bottom-up" "$(tail -c 6 rows-again.pgm | od -An -tu1 | tr -s ' ' ' ' | sed 's/^ //;s/ $//')" "5 6 3 4 1 2"
  expect "the PNM reader reads them top-down" "$(pixels rows.pgm)" "1|2|3|4|5|6|"

  cd ..
  ok "all tests passed"
}

case "$MODE" in
  link|all)
    msg "linkage and version ($TARGET)"
    for tool in $TOOLS; do
      assert_linkage "./$tool-$TARGET$EXE"
      grep -a -q -F "$OPENIMAGEIO_VERSION" "./$tool-$TARGET$EXE" || fail "$tool does not contain '$OPENIMAGEIO_VERSION'"
    done
    ok "the tools contain $OPENIMAGEIO_VERSION"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version and formats"
    expect "oiiotool --version" "$("./oiiotool-$TARGET$EXE" --version | tr -d '\r')" "$OPENIMAGEIO_VERSION"
    help="$("./oiiotool-$TARGET$EXE" --help | tr -d '\r')"
    inputs="$(printf '%s\n' "$help" | sed -n 's/^Input formats supported: //p' | head -n 1)"
    outputs="$(printf '%s\n' "$help" | sed -n 's/^Output formats supported: //p' | head -n 1)"
    for format in psd dpx cineon dds hdr tiff png openexr raw bmp targa pnm; do
      contains ", $inputs," ", $format," || fail "oiiotool reads no $format: $inputs"
    done
    ok "input formats: $inputs"
    for format in dpx hdr tiff png openexr; do
      contains ", $outputs," ", $format," || fail "oiiotool writes no $format: $outputs"
    done
    ok "output formats: $outputs"
    contains "$help" "LibRaw $LIBRAW_VERSION" || fail "oiiotool is not built with LibRaw $LIBRAW_VERSION"
    ok "built with LibRaw $LIBRAW_VERSION"
    tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
