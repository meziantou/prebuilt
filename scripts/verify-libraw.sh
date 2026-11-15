#!/usr/bin/env bash
#
# Verifies dcraw_emu, raw-identify and unprocessed_raw, built by
# scripts/build-libraw.sh.
#
#   bash scripts/verify-libraw.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage and version assertions only
#   run   version assertion plus the tests below (must run on the target)
#   all   both (default)
#
# The tests read a DNG file written byte by byte: 32 x 32 12-bit samples,
# uncompressed, an RGGB color filter array, DNG 1.4, white level 4095, an
# identity color matrix for D65 (LibRaw reads no image smaller than 22 pixels):
# - raw-identify names it, and -v prints its sizes, the filter pattern and
#   the DNG fields;
# - unprocessed_raw dumps the CFA samples, as stored, to a 16-bit PGM file;
# - dcraw_emu renders it, here linear 16-bit (-4) in the raw color space
#   (-o 0) with unit white balance, to a PPM file and a TIFF file (-T); the
#   bytes of the PPM file are pinned, the same on every runtime identifier.
#
# LIBRAW_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
[ -n "$LIBRAW_VERSION" ] || { echo "LIBRAW_VERSION is not set" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

TOOLS="dcraw_emu raw-identify unprocessed_raw"
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

# shellcheck source=verify-common.sh
. "$SCRIPT_DIR/verify-common.sh"

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

tests() {
  workdir="smoke-libraw-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"

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
  expect "the DNG file: 2048 bytes of samples after 410 bytes" "$(file_size test.dng)" "2458"

  msg "raw-identify"
  expect "raw-identify" "$("../raw-identify-$TARGET$EXE" test.dng | tr -d '\r')" "test.dng is a Prebuilt Tst image."
  verbose="$("../raw-identify-$TARGET$EXE" -v test.dng | tr -d '\r')"
  for line in " DNG Version: 1.4.0.0" "Image size:    32 x 32" "Raw colors: 3" "Filter pattern: RGGBRGGBRGGBRGGB" "DNG Illuminant 1: D65"; do
    contains "$verbose" "$line" || fail "raw-identify -v has no '$line': $verbose"
    ok "raw-identify -v: $line"
  done

  msg "unprocessed_raw: the CFA samples"
  "../unprocessed_raw-$TARGET$EXE" test.dng > tool.log 2>&1 || { cat tool.log >&2; fail "unprocessed_raw failed"; }
  same_file "unprocessed_raw writes the samples of the file, as stored" test.dng.pgm cfa-expected.pgm

  msg "dcraw_emu: the rendered image"
  "../dcraw_emu-$TARGET$EXE" -4 -o 0 -r 1 1 1 1 test.dng > tool.log 2>&1 || { cat tool.log >&2; fail "dcraw_emu failed"; }
  expect "a 16-bit 32 x 32 PPM file" "$(head -c 15 test.dng.ppm | tr '\n' '|')" "P6|32 32|65535|"
  expect "6159 bytes" "$(file_size test.dng.ppm)" "6159"
  expect "the bytes of the rendered image" "$(sha256_of test.dng.ppm)" "4b33f3dd75a6dc0667d05477a289b809eb086f0483b00c900bfabbb95c9d5887"
  "../dcraw_emu-$TARGET$EXE" -4 -T test.dng > tool.log 2>&1 || { cat tool.log >&2; fail "dcraw_emu -T failed"; }
  expect "dcraw_emu -T: a TIFF file" "$(hex_of_n test.dng.tiff 4)" "49492a00"

  cd ..
  ok "all tests passed"
}

case "$MODE" in
  link|all)
    msg "linkage and version ($TARGET)"
    for tool in $TOOLS; do
      assert_linkage "./$tool-$TARGET$EXE"
      grep -a -q -F "$LIBRAW_VERSION-Release" "./$tool-$TARGET$EXE" || fail "$tool does not contain '$LIBRAW_VERSION-Release'"
      ok "$tool: LibRaw $LIBRAW_VERSION-Release"
    done
    ;;
esac

case "$MODE" in
  run|all)
    tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
