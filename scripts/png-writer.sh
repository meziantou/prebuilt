# write_png, which writes the PNG files of the smoke tests of
# scripts/verify-pngquant.sh and scripts/verify-mozjpeg.sh from raw samples,
# with the tools of the machine: printf, od, awk, gzip, head and tail, and
# png_info, which prints the header and the chunks of a PNG file.
#
# The image data is a zlib stream of stored deflate blocks, without
# compression: a file is as large as its samples, so that pngquant always makes
# it smaller. The CRC-32 of a chunk is the one of the trailer gzip writes, and
# the Adler-32 of the zlib stream is computed with awk.
#
# Sourced by the verify scripts, after they define fail.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

# png_be32 <value>: prints the 4 bytes of the value, big-endian.
png_be32() {
  # shellcheck disable=SC2059
  printf "$(printf '\\%03o\\%03o\\%03o\\%03o' \
    $((($1 >> 24) & 255)) $((($1 >> 16) & 255)) $((($1 >> 8) & 255)) $(($1 & 255)))"
}

# png_le16 <value>: prints the 2 bytes of the value, little-endian.
png_le16() {
  # shellcheck disable=SC2059
  printf "$(printf '\\%03o\\%03o' $(($1 & 255)) $((($1 >> 8) & 255)))"
}

# png_crc32 <file>: the CRC-32 of the file, in decimal: the first 4 bytes of
# the 8-byte trailer of a gzip member, little-endian.
png_crc32() {
  gzip -c -n < "$1" | tail -c 8 | head -c 4 | od -An -v -tu1 \
    | awk '{ for (i = 1; i <= NF; i++) { value += $i * multiplier[i] } } BEGIN { multiplier[1] = 1; multiplier[2] = 256; multiplier[3] = 65536; multiplier[4] = 16777216 } END { printf "%d", value }'
}

# png_adler32 <file>: the Adler-32 of the file, in decimal.
png_adler32() {
  od -An -v -tu1 "$1" \
    | awk 'BEGIN { a = 1; b = 0 } { for (i = 1; i <= NF; i++) { a = (a + $i) % 65521; b = (b + a) % 65521 } } END { printf "%d", b * 65536 + a }'
}

# png_chunk <type> <data file>: prints a chunk, with its length and its CRC-32.
png_chunk() {
  printf '%s' "$1" > png-chunk.tmp
  cat "$2" >> png-chunk.tmp
  png_be32 "$(($(wc -c < "$2")))"
  cat png-chunk.tmp
  png_be32 "$(png_crc32 png-chunk.tmp)"
  rm -f png-chunk.tmp
}

# write_png <file> <width> <height> <bit depth> <color type> <scanlines file>:
# writes a PNG file of the scanlines, each one its filter type byte (0) and
# its samples.
write_png() {
  png_file="$1"; png_width="$2"; png_height="$3"; png_depth="$4"; png_type="$5"; png_scanlines="$6"

  { png_be32 "$png_width"; png_be32 "$png_height"
    # shellcheck disable=SC2059
    printf "$(printf '\\%03o\\%03o\\000\\000\\000' "$png_depth" "$png_type")"
  } > png-ihdr.tmp

  # zlib header (deflate, 32K window, no preset dictionary), the stored blocks
  # of at most 65535 bytes, the last one with BFINAL set, and the Adler-32.
  png_size=$(($(wc -c < "$png_scanlines")))
  printf '\170\001' > png-idat.tmp
  png_offset=0
  while :; do
    png_block=$((png_size - png_offset))
    [ "$png_block" -le 65535 ] || png_block=65535
    if [ $((png_offset + png_block)) -ge "$png_size" ]; then printf '\001' >> png-idat.tmp; else printf '\000' >> png-idat.tmp; fi
    { png_le16 "$png_block"; png_le16 $((png_block ^ 65535)); } >> png-idat.tmp
    tail -c +$((png_offset + 1)) "$png_scanlines" | head -c "$png_block" >> png-idat.tmp
    png_offset=$((png_offset + png_block))
    [ "$png_offset" -lt "$png_size" ] || break
  done
  png_be32 "$(png_adler32 "$png_scanlines")" >> png-idat.tmp

  : > png-iend.tmp
  { printf '\211PNG\r\n\032\n'
    png_chunk IHDR png-ihdr.tmp
    png_chunk IDAT png-idat.tmp
    png_chunk IEND png-iend.tmp
  } > "$png_file"
  rm -f png-ihdr.tmp png-idat.tmp png-iend.tmp
  # The signature, IHDR, IDAT (its zlib header, its blocks and their headers,
  # the Adler-32) and IEND: 12 bytes of length, type and CRC-32 per chunk.
  [ "$(($(wc -c < "$png_file")))" -eq $((8 + 25 + 12 + 2 + png_size + 5 * ((png_size + 65534) / 65535) + 4 + 12)) ] \
    || fail "$png_file was not written correctly"
}

# png_info <file>: prints "<width>x<height> depth <bit depth> type <color
# type>: <chunk type> <chunk type>...", or "not a PNG file".
png_info() {
  od -An -v -tu1 "$1" | awk '
    { for (i = 1; i <= NF; i++) byte[count++] = $i }
    function be32(p) { return ((byte[p] * 256 + byte[p + 1]) * 256 + byte[p + 2]) * 256 + byte[p + 3] }
    END {
      if (count < 33 || byte[0] != 137 || byte[1] != 80 || byte[2] != 78 || byte[3] != 71) { print "not a PNG file"; exit }
      line = be32(16) "x" be32(20) " depth " byte[24] " type " byte[25] ":"
      for (p = 8; p + 8 <= count; p += 12 + be32(p)) {
        line = line sprintf(" %c%c%c%c", byte[p + 4], byte[p + 5], byte[p + 6], byte[p + 7])
      }
      print line
    }'
}
