# The DNG file of the smoke tests of scripts/verify-libraw.sh and
# scripts/verify-openimageio.sh, written byte by byte: 32 x 32 12-bit samples,
# uncompressed, an RGGB color filter array, DNG 1.4, white level 4095, an
# identity color matrix for D65 (LibRaw reads no image smaller than 22
# pixels). Sourced by these scripts.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

# The printf escapes of little-endian numbers.
le16() { printf '\\%03o\\%03o' $(($1 & 255)) $((($1 >> 8) & 255)); }
le32() { printf '\\%03o\\%03o\\%03o\\%03o' $(($1 & 255)) $((($1 >> 8) & 255)) $((($1 >> 16) & 255)) $((($1 >> 24) & 255)); }
# entry <tag> <type> <count> <value escapes, 4 bytes>
entry() { printf '%s%s%s%s' "$(le16 "$1")" "$(le16 "$2")" "$(le32 "$3")" "$4"; }

# The sample of (x, y): 64 x + 100 y + 100, 12 bits.
sample() { echo $((($1 * 64 + $2 * 100 + 100) & 4095)); }

# write_dng <file> <CFA samples file>: a little-endian TIFF with one IFD of 23
# entries at 8, the values that do not fit in 4 bytes after it, then the
# samples (32 x 32, 16 bits).
write_dng() {
  ifd_end=$((8 + 2 + 23 * 12 + 4))   # 290
  make=$ifd_end                      # "Prebuilt", 9 bytes, padded to 10
  model_unique=$((make + 10))        # "Prebuilt Test", 14 bytes
  matrix=$((model_unique + 14))      # 9 SRATIONAL
  neutral=$((matrix + 72))           # 3 RATIONAL
  data=$((neutral + 24))
  {
    printf 'II*\000'; printf "$(le32 8)"; printf "$(le16 23)"
    printf "$(entry 254 4 1 "$(le32 0)")"
    printf "$(entry 256 3 1 "$(le16 32)\\000\\000")"
    printf "$(entry 257 3 1 "$(le16 32)\\000\\000")"
    printf "$(entry 258 3 1 "$(le16 16)\\000\\000")"
    printf "$(entry 259 3 1 "$(le16 1)\\000\\000")"
    printf "$(entry 262 3 1 "$(le16 32803)\\000\\000")"
    printf "$(entry 271 2 9 "$(le32 "$make")")"
    printf "$(entry 272 2 4 'Tst\000')"
    printf "$(entry 273 4 1 "$(le32 "$data")")"
    printf "$(entry 274 3 1 "$(le16 1)\\000\\000")"
    printf "$(entry 277 3 1 "$(le16 1)\\000\\000")"
    printf "$(entry 278 3 1 "$(le16 32)\\000\\000")"
    printf "$(entry 279 4 1 "$(le32 2048)")"
    printf "$(entry 284 3 1 "$(le16 1)\\000\\000")"
    printf "$(entry 33421 3 2 "$(le16 2)$(le16 2)")"
    printf "$(entry 33422 1 4 '\000\001\001\002')"
    printf "$(entry 50706 1 4 '\001\004\000\000')"
    printf "$(entry 50708 2 14 "$(le32 "$model_unique")")"
    printf "$(entry 50714 4 1 "$(le32 0)")"
    printf "$(entry 50717 4 1 "$(le32 4095)")"
    printf "$(entry 50721 10 9 "$(le32 "$matrix")")"
    printf "$(entry 50728 5 3 "$(le32 "$neutral")")"
    printf "$(entry 50778 3 1 "$(le16 21)\\000\\000")"
    printf "$(le32 0)"
    printf 'Prebuilt\000\000Prebuilt Test\000'
    for value in 1 0 0 0 1 0 0 0 1; do printf "$(le32 "$value")$(le32 1)"; done
    for value in 1 1 1; do printf "$(le32 "$value")$(le32 1)"; done
    cat "$2"
  } > "$1"
}

# write_test_dng <directory>: test.dng, cfa.raw (its samples, little-endian)
# and cfa-expected.pgm (the 16-bit big-endian PGM file of the samples).
write_test_dng() {
  (
    cd "$1"
    # The CFA samples, little-endian for the DNG file, and the 16-bit
    # big-endian PGM file unprocessed_raw is expected to write.
    : > cfa.raw
    { printf 'P5\n32 32\n65535\n'; } > cfa-expected.pgm
    y=0
    while [ "$y" -lt 32 ]; do
      le_row=""; be_row=""
      x=0
      while [ "$x" -lt 32 ]; do
        v="$(sample "$x" "$y")"
        le_row="$le_row$(le16 "$v")"
        be_row="$be_row$(printf '\\%03o\\%03o' $((v >> 8)) $((v & 255)))"
        x=$((x + 1))
      done
      printf "$le_row" >> cfa.raw
      printf "$be_row" >> cfa-expected.pgm
      y=$((y + 1))
    done
    write_dng test.dng cfa.raw
  )
}
