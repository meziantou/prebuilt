#!/usr/bin/env bash
#
# Verifies the psd-tools bundle built by scripts/build-psd-tools.sh:
# psd-tools-<target>.tar.gz, with the launcher (psd-tools, or psd-tools.exe on
# Windows), lib/psd-tools-cli.py, lib/wheels.txt and python/ at its root.
#
#   bash scripts/verify-psd-tools.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  bundle layout assertions (and the imports of psd-tools.exe) only
#   run   version assertion plus the tests below (must run on the target
#         platform, with magick-<target>, built by
#         scripts/build-imagemagick.sh, in the current directory)
#   all   both (default)
#
# The tests:
# - psd-tools alone: `psd-tools write` writes every color mode (RGB,
#   grayscale, CMYK, indexed, bitmap), depth (1, 8, 16, 32) and compression
#   (raw, RLE, ZIP, ZIP with prediction) of the composite, PSD and PSB files,
#   layers (in the layer info, or in the Lr16 and Lr32 blocks of 16 and 32-bit
#   files, as Photoshop writes them), a layer mask, an ICC profile, and a file
#   without a real composite ("Maximize Compatibility" off); `psd-tools dump`
#   gives every sample back, and the header and sections are the ones of the
#   description (scripts/psd-samples.sh parses them).
# - psd-tools reads what magick writes: the samples it dumps are the ones
#   magick was given, as stored (CMYK inverted, indexes, bits).
# - magick reads what psd-tools writes, with the same samples, but for what
#   magick does not read: ZIP composites (it merges the layers instead).
#
# What they found out, and assert:
# - magick writes a composite of separate zlib streams with -compress Zip,
#   which psd-tools rejects: "Decompressed length mismatch".
# - magick reads the composite of a file without a real composite
#   (hasComposite false) from its layers: the stored composite is not used.
#
# PSD_TOOLS_VERSION, PSD_TOOLS_PYTHON_VERSION, NUMPY_VERSION, PILLOW_VERSION and
# ATTRS_VERSION come from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
for name in PSD_TOOLS_VERSION PSD_TOOLS_PYTHON_VERSION NUMPY_VERSION PILLOW_VERSION ATTRS_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

ARCHIVE="./psd-tools-$TARGET.tar.gz"
[ -f "$ARCHIVE" ] || { echo "missing $ARCHIVE" >&2; exit 1; }

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

BUNDLE="./psd-tools-verify-$TARGET"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
tar -xzf "$ARCHIVE" -C "$BUNDLE"

if [ "$TARGET" = win-x64 ]; then
  PYTHON_REL="python/python.exe"
  SITE_PACKAGES_REL="python/Lib/site-packages"
else
  PYTHON_REL="python/bin/python3"
  SITE_PACKAGES_REL="python/lib/python$(echo "$PSD_TOOLS_PYTHON_VERSION" | cut -d . -f 1-2)/site-packages"
fi

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

find_objdump() {
  for candidate in x86_64-w64-mingw32-objdump objdump llvm-objdump; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

assert_layout() {
  for file in "psd-tools$EXE" lib/psd-tools-cli.py lib/wheels.txt "$PYTHON_REL" \
              "$SITE_PACKAGES_REL/psd_tools/__init__.py" "$SITE_PACKAGES_REL/numpy/__init__.py" \
              "$SITE_PACKAGES_REL/PIL/__init__.py" "$SITE_PACKAGES_REL/attrs/__init__.py"; do
    [ -f "$BUNDLE/$file" ] || fail "the bundle has no $file"
  done
  ok "the bundle has psd-tools$EXE, lib/ and python/"
  [ "$TARGET" = win-x64 ] || [ -x "$BUNDLE/psd-tools" ] || fail "psd-tools is not executable"

  wheels="$(cut -d ' ' -f 1 < "$BUNDLE/lib/wheels.txt" | tr -d '\r' | tr '\n' ' ')"
  for prefix in "psd_tools-$PSD_TOOLS_VERSION-" "numpy-$NUMPY_VERSION-" "pillow-$PILLOW_VERSION-" "attrs-$ATTRS_VERSION-"; do
    contains " $wheels" " $prefix" || fail "lib/wheels.txt has no $prefix wheel: $wheels"
  done
  ok "wheels: $wheels"
  for dist in "psd_tools-$PSD_TOOLS_VERSION" "numpy-$NUMPY_VERSION" "pillow-$PILLOW_VERSION" "attrs-$ATTRS_VERSION"; do
    [ -d "$BUNDLE/$SITE_PACKAGES_REL/$dist.dist-info" ] || fail "the bundle has no $dist.dist-info"
  done
  ok "the wheels are installed in $SITE_PACKAGES_REL"

  if [ "$TARGET" = win-x64 ]; then
    objdump="$(find_objdump)" || fail "no objdump or llvm-objdump to list the imports of psd-tools.exe"
    imports="$("$objdump" -p "$BUNDLE/psd-tools.exe" | sed -n 's/^[[:space:]]*DLL Name: //p' | tr 'A-Z' 'a-z' | tr -d '\r' | sort -u)"
    [ -n "$imports" ] || fail "could not list the imports of psd-tools.exe"
    for dll in $imports; do
      case "$dll" in
        kernel32.dll|ucrtbase.dll|api-ms-win-*) ;;
        *) fail "psd-tools.exe imports $dll" ;;
      esac
    done
    ok "psd-tools.exe imports only system DLLs ($(echo $imports | tr ' ' ','))"
  fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# json <header.json> <Python expression of d>: a value of a description, with
# the Python of the bundle.
json() {
  "$PY" -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" | tr -d '\r'
}

# write_desc <file> <JSON>: a description for psd-tools write.
write_desc() {
  printf '%s\n' "$2" > "$1"
}

# pt_write <label> <description> <output>
pt_write() {
  "$PT" write "$2" "$3" || fail "$1: psd-tools write failed"
  [ -s "$3" ] || fail "$1: psd-tools write wrote no $3"
}

# pt_dump <label> <file> <directory>
pt_dump() {
  rm -rf "$3"
  "$PT" dump "$2" "$3" || fail "$1: psd-tools dump of $2 failed"
}

# raw_of <file>[index] <depth> <map> [options...]: the samples magick reads,
# little-endian, the colors as stored for a composite with alpha.
raw_of() {
  raw_input="$1"; raw_depth="$2"; raw_map="$3"; shift 3
  if [ "$raw_depth" = 32 ]; then
    "$M" -define psd:alpha-unblend=off "$raw_input" "$@" -depth 32 -define quantum:format=floating-point -endian LSB "$raw_map:-"
  else
    "$M" -define psd:alpha-unblend=off "$raw_input" "$@" -depth "$raw_depth" -endian LSB "$raw_map:-"
  fi
}

# inverted <file> <8|16> <output>: 255 - x or 65535 - x, as PSD stores CMYK.
inverted() {
  if [ "$2" = 8 ]; then
    # shellcheck disable=SC2046
    write_bytes "$3" $(for v in $(dec "$1"); do echo $((255 - v)); done)
  else
    set -- "$1" "$2" "$3" $(dec "$1")
    inverted_file="$3"; shift 3
    inverted_bytes=""
    while [ $# -ge 2 ]; do
      v=$((65535 - ($1 + 256 * $2)))
      inverted_bytes="$inverted_bytes $((v & 255)) $((v >> 8))"
      shift 2
    done
    # shellcheck disable=SC2086
    write_bytes "$inverted_file" $inverted_bytes
  fi
}

# expand_palette <dump directory> <output>: the RGB samples of the indexes of
# an indexed composite.
expand_palette() {
  "$PY" -I -c '
import json, sys
d = json.load(open(sys.argv[1] + "/header.json"))
indexes = open(sys.argv[1] + "/composite.raw", "rb").read()
open(sys.argv[2], "wb").write(bytes(c for i in indexes for c in d["palette"][i]))
' "$1" "$2"
}

# The description of a flat file: <mode> <depth> <channels> <compression>
# <composite file> [version].
flat_desc() {
  printf '{"version": %s, "width": 4, "height": 2, "depth": %s, "colorMode": "%s", "channels": %s, "compression": "%s", "composite": "%s"}' \
    "${6:-1}" "$2" "$1" "$3" "$4" "$5"
}

# roundtrip <label> <description> <expected psd_info> <samples>: psd-tools
# writes the file, dumps it, and gives the samples back; the file is
# <label>.psd.
roundtrip() {
  name="$1"
  write_desc "$name.json" "$2"
  pt_write "$name" "$name.json" "$name.psd"
  expect "$name: header and sections" "$(psd_info "$name.psd")" "$3"
  pt_dump "$name" "$name.psd" "$name.dump"
  same_file "$name: psd-tools dumps the samples back" "$name.dump/composite.raw" "$4"
}

# im_reads <label> <file> <depth> <map> <expected samples> [read options...]
im_reads() {
  im_label="$1"; im_file="$2"; im_depth="$3"; im_map="$4"; im_expected="$5"; shift 5
  raw_of "$im_file[0]" "$im_depth" "$im_map" "$@" > im.raw || fail "$im_label: magick cannot read $im_file"
  same_file "$im_label: magick reads the samples" im.raw "$im_expected"
}

psd_tools_tests() {
  workdir="smoke-psd-tools-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  PT="../$BUNDLE/psd-tools$EXE"
  PY="../$BUNDLE/$PYTHON_REL"
  M="../magick-$TARGET$EXE"
  chmod +x "$M" 2>/dev/null || true
  [ -f "$M" ] || fail "missing magick-$TARGET$EXE (scripts/build-imagemagick.sh): the tests read and write files with it"
  write_samples .
  S="-size 4x2"

  # rgb32.raw: the floats of gray32.raw for R, G and B.
  set -- $(dec gray32.raw)
  rgb32=""
  while [ $# -ge 4 ]; do rgb32="$rgb32 $1 $2 $3 $4 $1 $2 $3 $4 $1 $2 $3 $4"; shift 4; done
  # shellcheck disable=SC2086
  write_bytes rgb32.raw $rgb32
  inverted cmyk8.raw 8 cmyk8-stored.raw
  inverted cmyk16.raw 16 cmyk16-stored.raw
  # bilevel8.raw as bitmap samples: 1 is black.
  write_bytes bits.raw 1 0 0 1 0 1 1 0

  # psd_info: version channels height width depth mode color-mode-data
  # resources layer-and-mask layer-count compression. psd-tools writes the
  # version info resource (1057): 12 bytes, then a version, hasComposite, the
  # writer and reader names ("psd-tools <version>", UTF-16 with a length),
  # and a file version, padded to an even length.
  writer="psd-tools $PSD_TOOLS_VERSION"
  R=$((4 + 1 + 2 * (4 + 2 * ${#writer}) + 4))
  R=$((12 + R + R % 2))

  msg "psd-tools: composites"
  for compression in RAW:0 RLE:1 ZIP:2 ZIP_WITH_PREDICTION:3; do
    c="${compression%:*}"; n="${compression#*:}"
    roundtrip "rgb8-$c" "$(flat_desc RGB 8 3 "$c" rgb8.raw)" "1 3 2 4 8 3 0 $R 4 - $n" rgb8.raw
    roundtrip "rgb16-$c" "$(flat_desc RGB 16 3 "$c" rgb16.raw)" "1 3 2 4 16 3 0 $R 4 - $n" rgb16.raw
    roundtrip "rgb32-$c" "$(flat_desc RGB 32 3 "$c" rgb32.raw)" "1 3 2 4 32 3 0 $R 4 - $n" rgb32.raw
  done
  roundtrip gray8 "$(flat_desc GRAYSCALE 8 1 RLE gray8.raw)" "1 1 2 4 8 1 0 $R 4 - 1" gray8.raw
  roundtrip gray16 "$(flat_desc GRAYSCALE 16 1 RLE gray16.raw)" "1 1 2 4 16 1 0 $R 4 - 1" gray16.raw
  roundtrip gray32 "$(flat_desc GRAYSCALE 32 1 ZIP_WITH_PREDICTION gray32.raw)" "1 1 2 4 32 1 0 $R 4 - 3" gray32.raw
  roundtrip cmyk8 "$(flat_desc CMYK 8 4 RLE cmyk8-stored.raw)" "1 4 2 4 8 4 0 $R 4 - 1" cmyk8-stored.raw
  roundtrip cmyk16 "$(flat_desc CMYK 16 4 RAW cmyk16-stored.raw)" "1 4 2 4 16 4 0 $R 4 - 0" cmyk16-stored.raw
  roundtrip rgba8 "$(flat_desc RGB 8 4 RLE rgba8.raw)" "1 4 2 4 8 3 0 $R 4 - 1" rgba8.raw
  roundtrip bitmap "$(flat_desc BITMAP 1 1 RLE bits.raw)" "1 1 2 4 1 0 0 $R 4 - 1" bits.raw
  # The RLE composite: 2 bytes for each of the 2 rows, then a literal of 1
  # byte for each: 1001 and 0110, padded with 0 bits (0x90, 0x60).
  tail -c 8 bitmap.psd > bitmap-rle.raw
  expect "bitmap: 1 bit per pixel, rows padded with 0 bits" "$(dec bitmap-rle.raw)" "0 2 0 2 0 144 0 96"
  roundtrip psb8 "$(flat_desc RGB 8 3 RLE rgb8.raw 2)" "2 3 2 4 8 3 0 $R 8 - 1" rgb8.raw
  roundtrip psb16 "$(flat_desc RGB 16 3 ZIP rgb16.raw 2)" "2 3 2 4 16 3 0 $R 8 - 2" rgb16.raw

  msg "psd-tools: indexed, ICC profile"
  # A palette of 256 colors: i, 255 - i, 7 i; the indexes 0, 1, 2, 3, 64,
  # 128, 200, 255.
  palette="[0, 255, 0]"
  i=1
  while [ "$i" -lt 256 ]; do palette="$palette, [$i, $((255 - i)), $((i * 7 % 256))]"; i=$((i + 1)); done
  write_bytes indexes.raw 0 1 2 3 64 128 200 255
  write_bytes indexed-rgb.raw 0 255 0 1 254 7 2 253 14 3 252 21 64 191 192 128 127 128 200 55 120 255 0 249
  roundtrip indexed "{\"width\": 4, \"height\": 2, \"depth\": 8, \"colorMode\": \"INDEXED\", \"channels\": 1, \"compression\": \"RLE\", \"composite\": \"indexes.raw\", \"palette\": [$(echo "$palette" | sed 's/^\[0, 255, 0\]/[0, 255, 0]/')], \"transparentIndex\": 3}" \
    "1 1 2 4 8 2 768 $((R + 14)) 4 - 1" indexes.raw
  expand_palette indexed.dump expanded.raw
  same_file "indexed: the palette of the dump" expanded.raw indexed-rgb.raw
  expect "indexed: the transparency index resource" "$(json indexed.dump/header.json 'd["transparentIndex"]')" "3"
  roundtrip icc "{\"width\": 4, \"height\": 2, \"depth\": 8, \"colorMode\": \"RGB\", \"channels\": 3, \"compression\": \"RLE\", \"composite\": \"rgb8.raw\", \"iccProfile\": \"test.icc\"}" \
    "1 3 2 4 8 3 0 $((R + 480)) 4 - 1" rgb8.raw
  same_file "icc: psd-tools dumps the profile back" icc.dump/icc.icc test.icc

  msg "psd-tools: layers"
  # Two layers: the left 2 x 2 RGBA pixels at (1, 0), and the first 2 RGBA
  # pixels at (0, 1), half opaque and hidden, with a mask.
  head -c 16 rgba8.raw > bottom8.raw
  head -c 8 rgba8.raw > top8.raw
  write_bytes mask8.raw 255 0
  layers_desc() {
    printf '{"width": 4, "height": 2, "depth": %s, "colorMode": "RGB", "channels": 4, "compression": "RLE", "composite": "%s", "mergedAlpha": true, %s"layers": [' "$1" "$2" "$4"
    printf '{"name": "Bottom", "top": 0, "left": 1, "bottom": 2, "right": 3, "channels": [0, 1, 2, -1], "compression": "%s", "file": "bottom%s.raw"},' "$3" "$1"
    printf '{"name": "Top", "top": 1, "left": 0, "bottom": 2, "right": 2, "opacity": 128, "visible": false, "channels": [0, 1, 2, -1], "compression": "%s", "file": "top%s.raw",' "$3" "$1"
    printf ' "mask": {"top": 1, "left": 0, "bottom": 2, "right": 2, "defaultColor": 0, "compression": "RAW", "file": "mask%s.raw"}}]}' "$1"
  }
  # The layer descriptions as psd-tools dumps them: name, bounds, opacity,
  # visibility, channels and compression; the mask bounds.
  layer_summary='"|".join("%s %d %d %d %d %d %s %s %s" % (l["name"], l["top"], l["left"], l["bottom"], l["right"], l["opacity"], l["visible"], l["channels"], l["compression"]) for l in d["layers"]) + " mask " + str([d["layers"][1]["mask"][k] for k in ("top", "left", "bottom", "right")])'
  expected_layers="Bottom 0 1 2 3 255 True [0, 1, 2, -1] RLE|Top 1 0 2 2 128 False [0, 1, 2, -1] RLE mask [1, 0, 2, 2]"
  write_desc layers8.json "$(layers_desc 8 rgba8.raw RLE '')"
  pt_write layers8 layers8.json layers8.psd
  expect "layers8: header and sections" "$(psd_info layers8.psd)" "1 4 2 4 8 3 0 $R 336 -2 1"
  pt_dump layers8 layers8.psd layers8.dump
  expect "layers8: the layers" "$(json layers8.dump/header.json "$layer_summary")" "$expected_layers"
  expect "layers8: the layer block, merged alpha" "$(json layers8.dump/header.json 'd["layerBlock"], d["mergedAlpha"]')" "('layerInfo', True)"
  same_file "layers8: the bottom layer" layers8.dump/layer-0.raw bottom8.raw
  same_file "layers8: the top layer" layers8.dump/layer-1.raw top8.raw
  same_file "layers8: the mask" layers8.dump/layer-1-mask.raw mask8.raw

  # 16 and 32 bits: the layers are in an Lr16 or Lr32 block, after an empty
  # layer info and global layer mask info.
  write_u16 bottom16.raw le 65535 0 1 65535 256 4660 43981 32768 0 65535 32768 1000 32767 2 513 0
  write_u16 top16.raw le 65535 0 1 65535 256 4660 43981 32768
  write_u16 mask16.raw le 65535 0
  write_u16 rgba16.raw le $(i=0; while [ $i -lt 32 ]; do echo $((i * 2000)); i=$((i + 1)); done)
  write_desc layers16.json "$(layers_desc 16 rgba16.raw ZIP_WITH_PREDICTION '')"
  pt_write layers16 layers16.json layers16.psd
  expect "layers16: header and sections (no layer info: an Lr16 block)" "$(psd_info layers16.psd)" "1 4 2 4 16 3 0 $R 408 - 1"
  pt_dump layers16 layers16.psd layers16.dump
  expect "layers16: the layer block" "$(json layers16.dump/header.json 'd["layerBlock"]')" "Lr16"
  same_file "layers16: the bottom layer" layers16.dump/layer-0.raw bottom16.raw
  same_file "layers16: the mask" layers16.dump/layer-1-mask.raw mask16.raw

  # 32-bit RGBA: the gray32.raw floats, the alpha 1.0.
  set -- $(dec gray32.raw)
  rgba32=""
  while [ $# -ge 4 ]; do rgba32="$rgba32 $1 $2 $3 $4 $1 $2 $3 $4 $1 $2 $3 $4 0 0 128 63"; shift 4; done
  # shellcheck disable=SC2086
  write_bytes rgba32.raw $rgba32
  head -c 64 rgba32.raw > bottom32.raw
  head -c 32 rgba32.raw > top32.raw
  write_bytes mask32.raw 0 0 128 63 0 0 0 0
  write_desc layers32.json "$(layers_desc 32 rgba32.raw ZIP '')"
  pt_write layers32 layers32.json layers32.psd
  pt_dump layers32 layers32.psd layers32.dump
  expect "layers32: the layer block" "$(json layers32.dump/header.json 'd["layerBlock"]')" "Lr32"
  same_file "layers32: the composite" layers32.dump/composite.raw rgba32.raw
  same_file "layers32: the bottom layer" layers32.dump/layer-0.raw bottom32.raw

  msg "psd-tools: no real composite (Maximize Compatibility off)"
  # One opaque layer over the whole image, and no composite: psd-tools write
  # fills it with white, and the version info resource says there is none.
  printf '{"width": 4, "height": 2, "depth": 8, "colorMode": "RGB", "channels": 3, "compression": "RLE", "composite": null, "hasComposite": false, "layers": [{"name": "All", "top": 0, "left": 0, "bottom": 2, "right": 4, "channels": [0, 1, 2], "compression": "RLE", "file": "rgb8.raw"}]}\n' > nocomposite.json
  pt_write nocomposite nocomposite.json nocomposite.psd
  pt_dump nocomposite nocomposite.psd nocomposite.dump
  expect "nocomposite: hasComposite" "$(json nocomposite.dump/header.json 'd["hasComposite"]')" "False"
  write_bytes white.raw 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255
  same_file "nocomposite: the stored composite is white" nocomposite.dump/composite.raw white.raw

  msg "the same bytes on every runtime identifier"
  expect "rgb16-ZIP_WITH_PREDICTION.psd" "$(sha256_of rgb16-ZIP_WITH_PREDICTION.psd)" "$PIN_RGB16_ZIPP"
  expect "layers8.psd" "$(sha256_of layers8.psd)" "$PIN_LAYERS8"
  # The ZIP data depends on the zlib of the Python: zlib on Linux and macOS,
  # zlib-ng on Windows (the MSVC build of python-build-standalone), which
  # compresses the layers of layers32.psd to other bytes (the same pixels).
  if [ "$TARGET" = win-x64 ]; then
    expect "layers32.psd (zlib-ng)" "$(sha256_of layers32.psd)" "$PIN_LAYERS32_ZLIB_NG"
  else
    expect "layers32.psd" "$(sha256_of layers32.psd)" "$PIN_LAYERS32"
  fi

  # -------------------------------------------------------------------------

  msg "psd-tools reads what magick writes"
  # magick_to_dump <name> <output> <expected composite> <magick options...>:
  # magick writes the output, psd-tools dumps it to <name>.mdump.
  magick_to_dump() {
    name="$1"; output="$2"; expected="$3"; shift 3
    "$M" "$@" "$output" || fail "$name: magick failed"
    pt_dump "$name" "${output#*:}" "$name.mdump"
    same_file "$name: psd-tools reads the composite magick writes" "$name.mdump/composite.raw" "$expected"
  }
  magick_to_dump im-rgb8 im-rgb8.psd rgb8.raw $S -depth 8 rgb:rgb8.raw -endian MSB -compress RLE
  same_file "im-rgb8: and its layer" im-rgb8.mdump/layer-0.raw rgb8.raw
  magick_to_dump im-rgb16 im-rgb16.psd rgb16.raw $S -depth 16 -endian LSB rgb:rgb16.raw -endian MSB -compress None
  magick_to_dump im-rgba8 im-rgba8.psd rgba8.raw $S -depth 8 rgba:rgba8.raw -endian MSB -compress RLE
  expect "im-rgba8: merged alpha" "$(json im-rgba8.mdump/header.json 'd["mergedAlpha"], d["layers"][0]["channels"]')" "(True, [0, 1, 2, -1])"
  magick_to_dump im-cmyk8 im-cmyk8.psd cmyk8-stored.raw $S -depth 8 cmyk:cmyk8.raw -endian MSB -compress RLE
  magick_to_dump im-cmyk16 im-cmyk16.psd cmyk16-stored.raw $S -depth 16 -endian LSB cmyk:cmyk16.raw -endian MSB -compress RLE
  magick_to_dump im-gray8 im-gray8.psd gray8.raw $S -depth 8 gray:gray8.raw -endian MSB -compress RLE
  magick_to_dump im-gray16 im-gray16.psd gray16.raw $S -depth 16 -endian LSB gray:gray16.raw -endian MSB -compress None
  magick_to_dump im-bitmap im-bitmap.psd bits.raw $S -depth 8 gray:bilevel8.raw -type Bilevel -depth 1 -endian MSB -compress RLE
  "$M" $S -depth 8 rgb:rgb8.raw -type Palette -endian MSB -compress RLE im-indexed.psd
  pt_dump im-indexed im-indexed.psd im-indexed.mdump
  expect "im-indexed: color mode" "$(json im-indexed.mdump/header.json 'd["colorMode"]')" "INDEXED"
  expand_palette im-indexed.mdump expanded.raw
  same_file "im-indexed: the palette colors of the indexes psd-tools reads" expanded.raw rgb8.raw
  magick_to_dump im-psb PSB:im-psb.psb rgb8.raw $S -depth 8 rgb:rgb8.raw -endian MSB -compress RLE
  "$M" $S -depth 8 rgb:rgb8.raw -profile test.icc -endian MSB -compress RLE im-icc.psd
  pt_dump im-icc im-icc.psd im-icc.mdump
  same_file "im-icc: psd-tools reads the profile magick writes" im-icc.mdump/icc.icc test.icc
  "$M" $S -depth 8 rgb:rgb8.raw \
    \( +clone -crop 2x2+0+0 +repage -set label Bottom -repage +1+0 \) \
    \( -clone 0 -crop 2x1+2+0 +repage -set label Top -repage +2+1 \) \
    -endian MSB -compress RLE im-layered.psd
  pt_dump im-layered im-layered.psd im-layered.mdump
  expect "im-layered: the layers psd-tools reads" "$(json im-layered.mdump/header.json '"|".join("%s %d %d %d %d %s" % (l["name"], l["top"], l["left"], l["bottom"], l["right"], l["channels"]) for l in d["layers"])')" \
    "Bottom 0 1 2 3 [0, 1, 2]|Top 1 2 2 4 [0, 1, 2]"
  write_bytes expected.raw 255 0 0 0 255 0 0 0 0 255 255 255
  same_file "im-layered: the bottom layer" im-layered.mdump/layer-0.raw expected.raw
  write_bytes expected.raw 0 0 255 128 128 128
  same_file "im-layered: the top layer" im-layered.mdump/layer-1.raw expected.raw
  "$M" $S -depth 8 rgb:rgb8.raw -endian MSB -compress Zip im-zip.psd
  status=0
  "$PT" dump im-zip.psd im-zip.mdump > zip-error.txt 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "psd-tools reads the ZIP composite of magick"
  contains "$(cat zip-error.txt)" "Decompressed length mismatch" || fail "psd-tools dump of a ZIP composite of magick: $(cat zip-error.txt)"
  ok "psd-tools rejects the ZIP composite of magick -compress Zip (Decompressed length mismatch)"

  msg "magick reads what psd-tools writes"
  for c in RAW RLE; do
    im_reads "rgb8-$c" "rgb8-$c.psd" 8 rgb rgb8.raw
    im_reads "rgb16-$c" "rgb16-$c.psd" 16 rgb rgb16.raw
    im_reads "rgb32-$c" "rgb32-$c.psd" 32 rgb rgb32.raw
  done
  for c in ZIP ZIP_WITH_PREDICTION; do
    status=0
    "$M" "rgb8-$c.psd[0]" -format '%w' info: > zip-warning.txt 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail "magick reads the $c composite of a file without layers"
    contains "$(cat zip-warning.txt)" "CompressionNotSupported" || fail "magick, $c composite: $(cat zip-warning.txt)"
    ok "magick does not read a $c composite (CompressionNotSupported)"
  done
  im_reads gray8 gray8.psd 8 gray gray8.raw
  im_reads gray16 gray16.psd 16 gray gray16.raw
  im_reads cmyk8 cmyk8.psd 8 cmyk cmyk8.raw
  im_reads cmyk16 cmyk16.psd 16 cmyk cmyk16.raw
  im_reads rgba8 rgba8.psd 8 rgba rgba8.raw
  im_reads bitmap bitmap.psd 8 gray bilevel8.raw
  im_reads indexed indexed.psd 8 rgb indexed-rgb.raw
  im_reads psb8 psb8.psd 8 rgb rgb8.raw
  "$M" icc.psd[0] icc-out.icc
  same_file "icc: magick reads the profile psd-tools writes" icc-out.icc test.icc
  im_reads layers8 layers8.psd 8 rgba rgba8.raw
  expect "layers8: the layers magick reads" "$("$M" layers8.psd -format '%l %g|' info: | tr -d '\r')" " 4x2+0+0|Bottom 2x2+1+0|Top 2x1+0+1|"
  raw_of "layers8.psd[1]" 8 rgba > im.raw
  same_file "layers8: magick reads the bottom layer" im.raw bottom8.raw
  im_reads layers16 layers16.psd 16 rgba rgba16.raw
  expect "layers16: magick reads the Lr16 layers" "$("$M" layers16.psd -format '%l %g|' info: | tr -d '\r')" " 4x2+0+0|Bottom 2x2+1+0|Top 2x1+0+1|"
  raw_of "layers16.psd[1]" 16 rgba > im.raw
  same_file "layers16: magick reads the bottom layer (ZIP with prediction)" im.raw bottom16.raw
  im_reads layers32 layers32.psd 32 rgba rgba32.raw
  raw_of "layers32.psd[1]" 32 rgba > im.raw
  same_file "layers32: magick reads the bottom layer of the Lr32 block (ZIP)" im.raw bottom32.raw
  # magick merges the layers: the opaque layer over the whole image.
  im_reads nocomposite nocomposite.psd 8 rgb rgb8.raw

  cd ..
  ok "all tests passed"
}

PIN_RGB16_ZIPP="ae58095929cb4915fc84bfa55071f07301b00a100bbc2f66b332f4b38d5cdc7d"
PIN_LAYERS8="1d2fa407d31194c28b622af20d4d11bfaf2c06726c887908b670ac95a7cad44f"
PIN_LAYERS32="eb78bca91fe6ac9c825ad7e2db1134aa47de2160dbb8efdadcc397989a5946c5"
PIN_LAYERS32_ZLIB_NG="68b4ec7f4424e3d67cdce90b066a3562c10866cb1f2902ccbeb680e073826555"

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "bundle layout ($TARGET)"
    assert_layout
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    version="$("$BUNDLE/psd-tools$EXE" --version | tr -d '\r')"
    expect "psd-tools --version" "$version" \
      "psd-tools $PSD_TOOLS_VERSION (Python $PSD_TOOLS_PYTHON_VERSION, numpy $NUMPY_VERSION, Pillow $PILLOW_VERSION)"
    psd_tools_tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
