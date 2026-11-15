#!/usr/bin/env bash
#
# Verifies magick, the ImageMagick tool built by scripts/build-imagemagick.sh.
#
#   bash scripts/verify-imagemagick.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage and version assertions only
#   run   version, delegates and formats, plus the PSD tests below (must run on
#         the target platform)
#   all   both (default)
#
# The tests write PSD and PSB files with magick, check the header and the
# sections of each with a parser of this repository (scripts/psd-samples.sh),
# and read them back with magick: the samples must be the ones written. What
# they found out about the PSD coder of ImageMagick, and assert:
# - It writes the color modes RGB, CMYK, grayscale, indexed (a palette image
#   of 256 colors at most, -type Palette) and bitmap (a bilevel image of depth
#   1), with 8 or 16 bits: a depth above 16 (-depth 32) is written with 16
#   bits. It writes RLE (-compress RLE) or raw (the default, or -compress
#   None) samples; -compress Zip is written as RLE.
# - It writes the image as the composite and as a layer: a list of images is
#   the composite and its layers (with -page offsets, and -set label names).
#   -define psd:write-layers=false writes the composite only, without layers.
#   An alpha channel is written as the extra channel of the composite, with a
#   negative layer count.
# - A layer read from a raw file (rgb:, gray:, ...) or made with xc: is
#   little-endian for ImageMagick, and the PSD coder then writes its blend
#   mode backwards ("mron" for "norm"), which other readers reject: write PSD
#   files with -endian MSB after the input images.
# - PSB:<file> writes a PSB (large document) file, version 2; a PSD wider or
#   higher than 30000 pixels is written as PSB.
# - -profile <file.icc> is written as the ICC profile resource (1039), and
#   read back as it was.
# - It reads 32-bit (float) samples: it is built with HDRI, and gives them
#   back with -depth 32 -define quantum:format=floating-point.
# - When it reads a composite with an alpha channel, it "unblends" the colors
#   from white, unless -define psd:alpha-unblend=off.
#
# IMAGEMAGICK_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
[ -n "$IMAGEMAGICK_VERSION" ] || { echo "IMAGEMAGICK_VERSION is not set" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

BIN="./magick-$TARGET$EXE"
[ -f "$BIN" ] || { echo "missing $BIN" >&2; exit 1; }
chmod +x "$BIN" 2>/dev/null || true

export LC_ALL=C
# Git Bash on Windows rewrites arguments that look like POSIX paths.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# shellcheck source=psd-samples.sh
. "$SCRIPT_DIR/psd-samples.sh"

# ---------------------------------------------------------------------------
# Linkage and version
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
        # libwinpthread-1.dll.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|ws2_32.dll|bcrypt.dll|urlmon.dll|ucrtbase.dll|api-ms-win-*) ;;
          *) bad="$bad $dll" ;;
        esac
      done
      [ -z "$bad" ] || fail "$bin imports non-system DLLs:$bad"
      ok "$bin imports only system DLLs ($(echo $imports | tr ' ' ','))"
      ;;
  esac
}

# The version string is in the binary: the Windows binaries are checked on
# the Linux machine that cross-compiles them.
assert_version_string() {
  grep -a -q -F "ImageMagick $IMAGEMAGICK_VERSION" "$BIN" || fail "$BIN does not contain 'ImageMagick $IMAGEMAGICK_VERSION'"
  ok "$BIN: ImageMagick $IMAGEMAGICK_VERSION"
}

# ---------------------------------------------------------------------------
# Version, delegates and formats
# ---------------------------------------------------------------------------

assert_features() {
  version="$("$BIN" -version | tr -d '\r')"
  first="$(printf '%s\n' "$version" | head -n 1)"
  contains "$first" "Version: ImageMagick $IMAGEMAGICK_VERSION Q16-HDRI " || fail "magick -version: $first"
  ok "$first"
  delegates="$(printf '%s\n' "$version" | sed -n 's/^Delegates (built-in): *//p' | sed 's/ *$//')"
  # A Windows build lists gslib and ps: it looks for a Ghostscript DLL to
  # read PostScript or PDF, and links no library for it.
  if [ "$TARGET" = win-x64 ]; then
    expect "delegates" "$delegates" "gslib lcms png ps tiff zlib"
  else
    expect "delegates" "$delegates" "lcms png tiff zlib"
  fi
  features="$(printf '%s\n' "$version" | sed -n 's/^Features: *//p')"
  for feature in HDRI Zero-configuration; do
    contains " $features " " $feature " || fail "magick -version has no $feature feature: $features"
  done
  for feature in OpenMP OpenCL Modules; do
    contains " $features " " $feature " && fail "magick -version has the $feature feature: $features"
  done
  ok "features: $features"

  formats="$("$BIN" -list format | tr -d '\r')"
  # The name, then * (a native blob support), then r, w and + (multiple images).
  for format in "PSB rw+" "PSD rw+" "PNG rw-" "TIFF rw+"; do
    name="${format% *}"; modes="${format#* }"
    line="$(printf '%s\n' "$formats" | sed -n "s/^ *$name\\* *//p" | head -n 1)"
    contains "$line" "$modes " || fail "magick -list format: $name is not '$modes': $line"
    ok "format $name: $modes"
  done
}

# ---------------------------------------------------------------------------
# PSD tests
# ---------------------------------------------------------------------------

# blend_modes <file>: the signatures and blend modes of the layer records
# ("8BIMnorm ..."), found in the bytes of the file.
blend_modes() {
  tr -c 'A-Za-z0-9' ' ' < "$1" | tr -s ' ' '\n' | grep -E '^8BIM[a-z]{4}$' | tr '\n' ' ' | sed 's/ $//'
}

# raw_of <file>[index] <depth> <map> [options...]: the samples magick reads,
# little-endian.
raw_of() {
  raw_input="$1"; raw_depth="$2"; raw_map="$3"; shift 3
  if [ "$raw_depth" = 32 ]; then
    "$M" -define psd:alpha-unblend=off "$raw_input" "$@" -depth 32 -define quantum:format=floating-point -endian LSB "$raw_map:-"
  else
    "$M" -define psd:alpha-unblend=off "$raw_input" "$@" -depth "$raw_depth" -endian LSB "$raw_map:-"
  fi
}

# check_psd <label> <file> <expected psd_info> <depth> <map> <expected samples file> [read options...]
check_psd() {
  label="$1"; file="$2"; expected_info="$3"; depth="$4"; map="$5"; samples="$6"; shift 6
  [ -s "$file" ] || fail "$label: $file was not written"
  expect "$label: header and sections" "$(psd_info "$file")" "$expected_info"
  raw_of "$file[0]" "$depth" "$map" "$@" > readback.raw || fail "$label: magick cannot read $file"
  same_file "$label: magick reads the samples back" readback.raw "$samples"
}

psd_tests() {
  workdir="smoke-imagemagick-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  M="../magick-$TARGET$EXE"
  write_samples .
  # The input images.
  S="-size 4x2"

  # psd_info: version channels height width depth mode color-mode-data
  # resources layer-and-mask layer-count compression. The resources are the
  # resolution (28 bytes) when the input has one; raw input has none.

  msg "RGB"
  "$M" $S -depth 8 rgb:rgb8.raw -endian MSB -compress RLE rgb8-rle.psd
  check_psd "RGB, 8 bits, RLE, with a layer" rgb8-rle.psd "1 3 2 4 8 3 0 0 134 1 1" 8 rgb rgb8.raw
  raw_of "rgb8-rle.psd[1]" 8 rgb > layer.raw
  same_file "the layer is the image" layer.raw rgb8.raw
  expect "the layer: name, size and offset" "$("$M" rgb8-rle.psd[1] -format '%l %g' info: | tr -d '\r')" "L1 4x2+0+0"
  "$M" $S -depth 8 rgb:rgb8.raw -endian MSB rgb8-raw.psd
  check_psd "RGB, 8 bits, raw (by default)" rgb8-raw.psd "1 3 2 4 8 3 0 0 104 1 0" 8 rgb rgb8.raw
  "$M" $S -depth 8 rgb:rgb8.raw -endian MSB -compress None -define psd:write-layers=false rgb8-flat.psd
  check_psd "RGB, 8 bits, raw, flat (psd:write-layers=false)" rgb8-flat.psd "1 3 2 4 8 3 0 0 0 - 0" 8 rgb rgb8.raw
  # -compress Zip writes ZIP layers, and a composite flagged ZIP (2) whose
  # planes are separate zlib streams: other readers reject it, and magick does
  # not read ZIP composites (it merges the layers instead).
  "$M" $S -depth 8 rgb:rgb8.raw -endian MSB -compress Zip rgb8-zip.psd
  expect "-compress Zip: a ZIP composite" "$(psd_info rgb8-zip.psd)" "1 3 2 4 8 3 0 0 128 1 2"
  raw_of "rgb8-zip.psd[1]" 8 rgb > layer.raw
  same_file "-compress Zip: magick reads the ZIP layer" layer.raw rgb8.raw
  status=0
  "$M" rgb8-zip.psd[0] -format '%w' info: > zip-warning.txt 2>&1 || status=$?
  contains "$(cat zip-warning.txt)" "CompressionNotSupported '2'" || fail "magick reads a ZIP composite: $(cat zip-warning.txt)"
  ok "magick does not read a ZIP composite (CompressionNotSupported '2'): it merges the layers"
  "$M" $S -depth 16 -endian LSB rgb:rgb16.raw -endian MSB -compress RLE rgb16-rle.psd
  check_psd "RGB, 16 bits, RLE" rgb16-rle.psd "1 3 2 4 16 3 0 0 157 1 1" 16 rgb rgb16.raw
  "$M" $S -depth 16 -endian LSB rgb:rgb16.raw -endian MSB -compress None -define psd:write-layers=false rgb16-raw.psd
  check_psd "RGB, 16 bits, raw, flat" rgb16-raw.psd "1 3 2 4 16 3 0 0 0 - 0" 16 rgb rgb16.raw
  "$M" $S -depth 16 -endian LSB rgb:rgb16.raw -depth 32 -endian MSB -compress RLE rgb32.psd
  expect "-depth 32 is written with 16 bits" "$(psd_info rgb32.psd)" "1 3 2 4 16 3 0 0 157 1 1"
  "$M" $S -depth 8 rgba:rgba8.raw -endian MSB -compress RLE rgba8.psd
  check_psd "RGB with alpha: 4 channels, a negative layer count" rgba8.psd "1 4 2 4 8 3 0 0 160 -1 1" 8 rgba rgba8.raw
  raw_of "rgba8.psd[1]" 8 rgba > layer.raw
  same_file "the layer has the transparency" layer.raw rgba8.raw
  # Read with the default, the colors are unblended from white.
  "$M" rgba8.psd[0] -depth 8 rgba:- > unblended.raw
  cmp -s unblended.raw rgba8.raw && fail "the colors of a composite with alpha are read without unblending"
  ok "without psd:alpha-unblend=off, the colors of a composite with alpha change"

  msg "CMYK"
  "$M" $S -depth 8 cmyk:cmyk8.raw -endian MSB -compress RLE cmyk8.psd
  check_psd "CMYK, 8 bits, RLE" cmyk8.psd "1 4 2 4 8 4 0 0 156 1 1" 8 cmyk cmyk8.raw
  # PSD stores the CMYK samples inverted: 255 is no ink. The 8 bytes of the
  # composite are the first scan line of the cyan plane, RLE encoded: 2 bytes
  # for each of the 8 scan lines of the 4 planes, then the data.
  "$M" $S -depth 8 cmyk:cmyk8.raw -endian MSB -compress None -define psd:write-layers=false cmyk8-raw.psd
  check_psd "CMYK, 8 bits, raw, flat" cmyk8-raw.psd "1 4 2 4 8 4 0 0 0 - 0" 8 cmyk cmyk8.raw
  expect "the cyan plane is stored inverted" "$(od -An -v -tu1 -j 40 -N 8 cmyk8-raw.psd | tr -s ' ' ' ' | sed 's/^ //;s/ $//')" "0 255 255 255 255 191 245 55"
  "$M" $S -depth 16 -endian LSB cmyk:cmyk16.raw -endian MSB -compress RLE cmyk16.psd
  check_psd "CMYK, 16 bits, RLE" cmyk16.psd "1 4 2 4 16 4 0 0 176 1 1" 16 cmyk cmyk16.raw

  msg "grayscale"
  "$M" $S -depth 8 gray:gray8.raw -endian MSB -compress RLE gray8.psd
  check_psd "grayscale, 8 bits, RLE" gray8.psd "1 1 2 4 8 1 0 0 82 1 1" 8 gray gray8.raw
  "$M" $S -depth 16 -endian LSB gray:gray16.raw -endian MSB -compress None gray16.psd
  check_psd "grayscale, 16 bits, raw" gray16.psd "1 1 2 4 16 1 0 0 80 1 0" 16 gray gray16.raw

  msg "indexed"
  "$M" $S -depth 8 rgb:rgb8.raw -type Palette -endian MSB -compress RLE indexed.psd
  check_psd "indexed: 8 bits, a palette of 768 bytes" indexed.psd "1 1 2 4 8 2 768 0 82 1 1" 8 rgb rgb8.raw
  "$M" $S -depth 8 rgb:rgb8.raw -type Palette -endian MSB -compress None -define psd:write-layers=false indexed-raw.psd
  check_psd "indexed, raw, flat" indexed-raw.psd "1 1 2 4 8 2 768 0 0 - 0" 8 rgb rgb8.raw

  msg "bitmap"
  "$M" $S -depth 8 gray:bilevel8.raw -type Bilevel -depth 1 -endian MSB -compress RLE bitmap.psd
  check_psd "bitmap: 1 bit" bitmap.psd "1 1 2 4 1 0 0 0 74 1 1" 8 gray bilevel8.raw
  "$M" $S -depth 8 gray:bilevel8.raw -type Bilevel -depth 1 -endian MSB -compress None -define psd:write-layers=false bitmap-raw.psd
  check_psd "bitmap, raw, flat" bitmap-raw.psd "1 1 2 4 1 0 0 0 0 - 0" 8 gray bilevel8.raw
  # 1 is black: 0 255 255 0 is 1001, 255 0 0 255 is 0110, and magick pads
  # the rows with 1 bits: 0x9F, 0x6F.
  expect "bitmap samples: 1 bit per pixel, 1 is black, rows padded with 1 bits" "$(od -An -v -tu1 -j 40 -N 2 bitmap-raw.psd | tr -s ' ' ' ' | sed 's/^ //;s/ $//')" "159 111"
  "$M" $S -depth 8 gray:bilevel8.raw -endian MSB -compress RLE bilevel-gray.psd
  expect "a bilevel image of depth 8 is grayscale" "$(psd_info bilevel-gray.psd)" "1 1 2 4 8 1 0 0 82 1 1"

  msg "layers"
  # The layers are the left 2 x 2 pixels at (1, 0), and the 2 x 1 pixels at
  # (2, 0) at (2, 1).
  "$M" $S -depth 8 rgb:rgb8.raw \
    \( +clone -crop 2x2+0+0 +repage -set label Bottom -repage +1+0 \) \
    \( -clone 0 -crop 2x1+2+0 +repage -set label Top -repage +2+1 \) \
    -endian MSB -compress RLE layered.psd
  check_psd "a composite and 2 layers" layered.psd "1 3 2 4 8 3 0 0 208 2 1" 8 rgb rgb8.raw
  expect "the layers: names, sizes and offsets" "$("$M" layered.psd -format '%l %g|' info: | tr -d '\r')" " 4x2+0+0|Bottom 2x2+1+0|Top 2x1+2+1|"
  expect "the blend modes of the layers" "$(blend_modes layered.psd)" "8BIMnorm 8BIMnorm"
  raw_of "layered.psd[1]" 8 rgb > layer.raw
  write_bytes expected.raw 255 0 0 0 255 0 0 0 0 255 255 255
  same_file "the samples of the bottom layer" layer.raw expected.raw
  raw_of "layered.psd[2]" 8 rgb > layer.raw
  write_bytes expected.raw 0 0 255 128 128 128
  same_file "the samples of the top layer" layer.raw expected.raw
  "$M" $S -depth 8 rgb:rgb8.raw \( +clone -crop 2x2+0+0 +repage -repage +1+0 \) -compress RLE backwards.psd
  expect "without -endian MSB, the blend mode of a raw layer is written backwards" "$(blend_modes backwards.psd)" "8BIMmron"

  msg "PSB"
  "$M" $S -depth 8 rgb:rgb8.raw -endian MSB -compress RLE PSB:rgb8.psb
  check_psd "PSB: version 2, 8-byte lengths, 4-byte RLE counts" rgb8.psb "2 3 2 4 8 3 0 0 162 1 1" 8 rgb rgb8.raw
  "$M" $S -depth 16 -endian LSB cmyk:cmyk16.raw -endian MSB -compress None -define psd:write-layers=false PSB:cmyk16.psb
  check_psd "PSB, CMYK, 16 bits, raw, flat" cmyk16.psb "2 4 2 4 16 4 0 0 0 - 0" 16 cmyk cmyk16.raw

  msg "ICC profile"
  "$M" $S -depth 8 rgb:rgb8.raw -profile test.icc -endian MSB -compress RLE icc.psd
  # The resource block: 8BIM, 0x040F, an empty name, the length, the profile.
  check_psd "an ICC profile resource of 12 + 468 bytes" icc.psd "1 3 2 4 8 3 0 480 134 1 1" 8 rgb rgb8.raw
  expect "the ICC profile resource" "$(od -An -c -j 34 -N 4 icc.psd | tr -d ' ')/$(be icc.psd 38 2)/$(be icc.psd 42 4)" "8BIM/1039/468"
  "$M" icc.psd[0] icc-out.icc
  same_file "magick reads the profile back" icc-out.icc test.icc
  expect "the description of the profile" "$("$M" icc.psd[0] -format '%[icc:description]' info: | tr -d '\r')" "Prebuilt test RGB"

  msg "reading 32-bit and PSB files written byte by byte"
  # The planes of the composite, big-endian: gray32.raw is little-endian.
  od -An -v -tu1 gray32.raw | tr -s ' \n\r' '   ' > gray32.txt
  set -- $(cat gray32.txt)
  be_bytes=""
  while [ $# -ge 4 ]; do be_bytes="$be_bytes $4 $3 $2 $1"; shift 4; done
  # shellcheck disable=SC2086
  write_bytes gray32-be.raw $be_bytes
  write_flat_psd gray32.psd 1 1 32 1 gray32-be.raw
  check_psd "grayscale, 32 bits (floats), raw" gray32.psd "1 1 2 4 32 1 0 0 0 - 0" 32 gray gray32.raw
  write_flat_psd gray32.psb 2 1 32 1 gray32-be.raw
  check_psd "PSB, grayscale, 32 bits, raw" gray32.psb "2 1 2 4 32 1 0 0 0 - 0" 32 gray gray32.raw
  # 3 planes of 32-bit floats: the gray samples, then 2 copies of them.
  cat gray32-be.raw gray32-be.raw gray32-be.raw > rgb32-be.raw
  write_flat_psd rgb32.psd 1 3 32 3 rgb32-be.raw
  raw_of "rgb32.psd[0]" 32 gray -channel R -separate > red.raw
  same_file "RGB, 32 bits: the red plane" red.raw gray32.raw

  msg "the same bytes on every runtime identifier"
  expect "rgb8-rle.psd" "$(sha256_of rgb8-rle.psd)" "$PIN_RGB8_RLE"
  expect "cmyk16.psd" "$(sha256_of cmyk16.psd)" "$PIN_CMYK16"
  expect "indexed.psd" "$(sha256_of indexed.psd)" "$PIN_INDEXED"
  expect "layered.psd" "$(sha256_of layered.psd)" "$PIN_LAYERED"

  cd ..
  ok "all tests passed"
}

PIN_RGB8_RLE="444c4d46e124e149d93098a2358760b8aec07be53cd0ed1fcc7783d1681a950a"
PIN_CMYK16="4b3b5ece138d437af053da0d96fdbe67cdbe3520414093085908efdb22a50871"
PIN_INDEXED="07a791474ad046cc520ee538481914fbe31bf89e8c5ad82db684c56a0b826de1"
PIN_LAYERED="75f43440968ec30a92c388603c7b67f75871fcda17d4a9979cc084056ea47763"

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage and version ($TARGET)"
    assert_linkage "$BIN"
    assert_version_string
    ;;
esac

case "$MODE" in
  run|all)
    msg "version, delegates and formats"
    assert_features
    psd_tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
