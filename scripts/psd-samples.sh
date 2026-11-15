# The sample images and the PSD parsing of the smoke tests of
# scripts/verify-imagemagick.sh and scripts/verify-psd-tools.sh. Sourced by
# these scripts, after they define fail and ok.
#
# The samples are 4 x 2 pixels, written byte by byte, so that every value is
# known: raw samples as `magick -size 4x2 -depth N rgb:` (and gray:, cmyk:)
# reads them, and as `psd-tools write` reads them (little-endian).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

# write_bytes <file> <decimal byte>...
write_bytes() {
  write_bytes_file="$1"; shift
  write_bytes_format=""
  for write_bytes_value in "$@"; do
    write_bytes_format="$write_bytes_format\\$(printf '%03o' "$write_bytes_value")"
  done
  # shellcheck disable=SC2059
  printf "$write_bytes_format" > "$write_bytes_file"
}

# write_u16 <file> <le|be> <value>...: 16-bit samples.
write_u16() {
  write_u16_file="$1"; write_u16_order="$2"; shift 2
  write_u16_bytes=""
  for write_u16_value in "$@"; do
    if [ "$write_u16_order" = le ]; then
      write_u16_bytes="$write_u16_bytes $((write_u16_value & 255)) $((write_u16_value >> 8))"
    else
      write_u16_bytes="$write_u16_bytes $((write_u16_value >> 8)) $((write_u16_value & 255))"
    fi
  done
  # shellcheck disable=SC2086
  write_bytes "$write_u16_file" $write_u16_bytes
}

# The decimal bytes of a file, separated by spaces.
dec() {
  od -An -v -tu1 "$1" | tr -s ' \n\r' '   ' | sed -e 's/^ //' -e 's/ $//'
}

# The hexadecimal digits of a file.
hex_of() {
  od -An -v -tx1 "$1" | tr -d ' \n\r'
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# expect <label> <actual> <expected>
expect() {
  [ "$2" = "$3" ] || fail "$1:
  actual:   $2
  expected: $3"
  ok "$1"
}

# same_file <label> <actual file> <expected file>
same_file() {
  [ -f "$2" ] || fail "$1: $2 was not written"
  cmp -s "$2" "$3" || fail "$1:
  $2: $(dec "$2" | cut -c1-200)
  $3: $(dec "$3" | cut -c1-200)"
  ok "$1"
}

# ---------------------------------------------------------------------------
# Samples
# ---------------------------------------------------------------------------

# 8 RGB pixels: red, green, blue, gray, black, white, and two others.
SAMPLE_RGB8="255 0 0 0 255 0 0 0 255 128 128 128 0 0 0 255 255 255 16 32 48 192 176 160"
# The same with an alpha channel: 255, 128, 0, 64, ...
SAMPLE_RGBA8="255 0 0 255 0 255 0 128 0 0 255 0 128 128 128 64 0 0 0 255 255 255 255 32 16 32 48 200 192 176 160 1"
# 16-bit RGB samples, which 8 bits do not hold.
SAMPLE_RGB16="65535 0 1 256 4660 43981 0 65535 32768 32767 2 513 7 65534 1000 60000 12345 54321 1 2 3 40000 50000 65000"
SAMPLE_GRAY8="0 255 128 64 32 200 17 99"
SAMPLE_GRAY16="0 65535 32768 4660 1 65534 43981 999"
# The ink of 8 CMYK pixels.
SAMPLE_CMYK8="255 0 0 0 0 255 0 0 0 0 255 0 0 0 0 255 0 0 0 0 64 128 192 32 10 20 30 40 200 150 100 50"
SAMPLE_CMYK16="65535 0 0 0 0 65535 0 0 0 0 65535 0 0 0 0 65535 0 0 0 0 4660 43981 1 65534 1000 2000 3000 4000 51400 38550 25700 12850"
# Black and white: 0 is black for gray samples.
SAMPLE_BILEVEL8="0 255 255 0 255 0 0 255"
# 32-bit floats, little-endian: 0, 1, 0.5, 0.25, 2 (above white), 0.125,
# 0.0625 and 0.75.
SAMPLE_GRAY32="0 0 0 0 0 0 128 63 0 0 0 63 0 0 128 62 0 0 0 64 0 0 0 62 0 0 128 61 0 0 64 63"

# write_samples <directory>: rgb8.raw, rgba8.raw, rgb16.raw (little-endian),
# gray8.raw, gray16.raw, cmyk8.raw, cmyk16.raw, bilevel8.raw, gray32.raw
# (little-endian floats), and test.icc.
write_samples() {
  # shellcheck disable=SC2086
  {
    write_bytes "$1/rgb8.raw" $SAMPLE_RGB8
    write_bytes "$1/rgba8.raw" $SAMPLE_RGBA8
    write_u16 "$1/rgb16.raw" le $SAMPLE_RGB16
    write_bytes "$1/gray8.raw" $SAMPLE_GRAY8
    write_u16 "$1/gray16.raw" le $SAMPLE_GRAY16
    write_bytes "$1/cmyk8.raw" $SAMPLE_CMYK8
    write_u16 "$1/cmyk16.raw" le $SAMPLE_CMYK16
    write_bytes "$1/bilevel8.raw" $SAMPLE_BILEVEL8
    write_bytes "$1/gray32.raw" $SAMPLE_GRAY32
  }
  write_test_icc "$1/test.icc"
}

# write_test_icc <file>: a 468-byte ICC v2.1 RGB display profile (matrix and
# gamma 2.2 curves, D50 white point), "Prebuilt test RGB": no tool of the
# bundles ships a profile.
write_test_icc() {
  {
    # Header (128 bytes), tag table (desc, cprt, wtpt, rXYZ, gXYZ, bXYZ, and
    # rTRC, gTRC and bTRC sharing one curve), then the tags.
    printf '\000\000\001\324none\002\020\000\000mntrRGB XYZ \007\352\000\001\000\001\000\000\000\000\000\000acsp'
    printf 'APPL\000\000\000\000nonenone\000\000\000\000\000\000\000\000\000\000\000\000\000\000\366\326\000\001\000\000\000\000\323\055'
    printf 'none\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000'
    printf '\000\000\000\000\000\000\000\000'
    printf '\000\000\000\011desc\000\000\000\360\000\000\000lcprt\000\000\001\134\000\000\000\025wtpt\000\000\001t\000\000\000\024'
    printf 'rXYZ\000\000\001\210\000\000\000\024gXYZ\000\000\001\234\000\000\000\024bXYZ\000\000\001\260\000\000\000\024rTRC'
    printf '\000\000\001\304\000\000\000\016gTRC\000\000\001\304\000\000\000\016bTRC\000\000\001\304\000\000\000\016'
    printf 'desc\000\000\000\000\000\000\000\022Prebuilt test RGB\000\000\000\000\000\000\000\000\000\000\000'
    printf '\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000'
    printf '\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000'
    printf 'text\000\000\000\000No copyright\000\000\000\000'
    printf 'XYZ \000\000\000\000\000\000\366\326\000\001\000\000\000\000\323\055'
    printf 'XYZ \000\000\000\000\000\000o\244\000\000\070\366\000\000\003\217'
    printf 'XYZ \000\000\000\000\000\000b\226\000\000\267\207\000\000\030\334'
    printf 'XYZ \000\000\000\000\000\000\044\242\000\000\017\203\000\000\266\317'
    printf 'curv\000\000\000\000\000\000\000\001\002\063\000\000'
  } > "$1"
  [ "$(wc -c < "$1" | tr -d ' ')" = 468 ] || fail "the test ICC profile has $(wc -c < "$1") bytes, not 468"
}

# ---------------------------------------------------------------------------
# PSD parsing
# ---------------------------------------------------------------------------

# be <file> <offset> <bytes>: a big-endian unsigned number.
be() {
  be_value=0
  for be_byte in $(od -An -v -tu1 -j "$2" -N "$3" "$1"); do
    be_value=$((be_value * 256 + be_byte))
  done
  echo "$be_value"
}

# psd_info <file>: "<version> <channels> <height> <width> <depth> <mode>
# <color mode data length> <resources length> <layer and mask length>
# <layer count> <compression of the composite>", from the sections of the
# file. The layer count is the one of the layer info (negative: the first
# extra channel is the transparency of the composite), or "-" when the layer
# info is empty.
psd_info() {
  [ "$(od -An -c -N 4 "$1" | tr -d ' ')" = 8BPS ] || fail "$1 is not a PSD file"
  info_version="$(be "$1" 4 2)"
  info_size=4
  [ "$info_version" = 2 ] && info_size=8
  info_offset=26
  info_cm="$(be "$1" "$info_offset" 4)"
  info_offset=$((info_offset + 4 + info_cm))
  info_resources="$(be "$1" "$info_offset" 4)"
  info_offset=$((info_offset + 4 + info_resources))
  info_lm="$(be "$1" "$info_offset" "$info_size")"
  info_count="-"
  if [ "$info_lm" -gt 0 ]; then
    info_li="$(be "$1" $((info_offset + info_size)) "$info_size")"
    if [ "$info_li" -gt 0 ]; then
      info_count="$(be "$1" $((info_offset + 2 * info_size)) 2)"
      [ "$info_count" -ge 32768 ] && info_count=$((info_count - 65536))
    fi
  fi
  info_offset=$((info_offset + info_size + info_lm))
  echo "$info_version $(be "$1" 12 2) $(be "$1" 14 4) $(be "$1" 18 4) $(be "$1" 22 2) $(be "$1" 24 2) $info_cm $info_resources $info_lm $info_count $(be "$1" "$info_offset" 2)"
}

# write_flat_psd <file> <version> <channels> <depth> <mode> <samples file>:
# a 4 x 2 PSD (version 1) or PSB (2) file without color mode data, image
# resources or layers, with the raw (uncompressed) composite of the samples
# file, which holds the planes one after the other, big-endian.
write_flat_psd() {
  if [ "$2" = 2 ]; then flat_lm="0 0 0 0 0 0 0 0"; else flat_lm="0 0 0 0"; fi
  # Signature, version, 6 reserved bytes, channels, height 2, width 4, depth,
  # mode; empty color mode data, image resources and layer and mask
  # information; raw samples.
  # shellcheck disable=SC2086
  write_bytes "$1" 56 66 80 83 0 "$2" 0 0 0 0 0 0 0 "$3" 0 0 0 2 0 0 0 4 0 "$4" 0 "$5" \
    0 0 0 0 0 0 0 0 $flat_lm 0 0
  cat "$6" >> "$1"
}
