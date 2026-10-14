#!/usr/bin/env bash
#
# Verifies iso-jpeg, the jpeg tool of the ISO JPEG reference codec built by
# scripts/build-iso-jpeg.sh.
#
#   bash scripts/verify-iso-jpeg.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   usage assertions plus real encode+decode round-trips of what the tool
#         is published for (must run on the target platform)
#   all   both (default)
#
# The tool has no version option and prints no version anywhere, so there is no
# version assertion: the sources are pinned by commit in build-iso-jpeg.sh,
# which checks the release they declare.
#
# What a caller of the tool has to know, and what this script does about it:
# - It exits with 0 when a conversion fails: it prints the error, and leaves an
#   empty output file or does not touch it, so that a file of a previous
#   conversion can still be there. Only a command line it does not understand
#   gives another exit code. Every conversion here starts without its output
#   file and is checked through the file it writes, never through the exit
#   code alone.
# - Lossless encoding (-p) fails at the pinned commit with "error -1031 - DQT
#   marker missing", so it is not asserted.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

ISO_JPEG="./iso-jpeg-$TARGET$EXE"
[ -f "$ISO_JPEG" ] || { echo "missing $ISO_JPEG" >&2; exit 1; }
chmod +x "$ISO_JPEG" 2>/dev/null || true

# The test images are written byte by byte with printf.
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

# The llvm-mingw objdump comes first: the Windows binary is checked on the
# Linux machine that cross-compiles it.
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
        # libc++.dll, libunwind.dll or libwinpthread-1.dll.
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
# Usage
# ---------------------------------------------------------------------------

# Without an argument, the tool prints its usage and fails.
assert_usage() {
  status=0
  usage="$("$ISO_JPEG" 2>&1 | tr -d '\r')" || status=$?
  [ "$status" -ne 0 ] || fail "iso-jpeg without an argument succeeded: $usage"
  contains "$usage" "[options] source target" || fail "iso-jpeg without an argument does not print its usage: $usage"
  for option in -q -a -v -h -z -s -c -y -n; do
    contains "$usage" $'\n'"$option " || fail "the usage of iso-jpeg does not list $option"
  done
  ok "iso-jpeg prints its usage (exit code $status)"
  ok "the usage lists -q -a -v -h -z -s -c -y -n"
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

WIDTH=52
HEIGHT=38

# gradient <maximum>: prints the samples of an RGB image of $WIDTH x $HEIGHT
# pixels, a smooth gradient with some texture so that the blocks have AC
# coefficients for the progressive scans. A sample is one byte up to 255, and
# two above, the most significant one first, as in a PNM file.
gradient() {
  maximum="$1"
  y=0
  while [ "$y" -lt "$HEIGHT" ]; do
    row=""
    x=0
    while [ "$x" -lt "$WIDTH" ]; do
      texture=$((x * y % 7 * maximum / 56))
      for base in $((x * maximum / (WIDTH - 1))) $((y * maximum / (HEIGHT - 1))) $(((x + y) * maximum / (WIDTH + HEIGHT - 2))); do
        value=$((base * 7 / 8 + texture))
        printf -v low '%03o' $((value & 255))
        if [ "$maximum" -gt 255 ]; then
          printf -v high '%03o' $((value >> 8))
          row="$row\\$high\\$low"
        else
          row="$row\\$low"
        fi
      done
      x=$((x + 1))
    done
    # shellcheck disable=SC2059
    printf "$row"
    y=$((y + 1))
  done
}

# run <label> <output file> <command...>: the command succeeds and writes the
# file, which is removed first. The file is what tells a conversion worked: the
# tool exits with 0 when it fails.
run() {
  label="$1"; out="$2"; shift 2
  rm -f "$out"
  "$@" > tool.log 2>&1 || { cat tool.log >&2; fail "$label: $(basename "$1") failed"; }
  [ -s "$out" ] || { cat tool.log >&2; fail "$label: $(basename "$1") wrote no $out"; }
}

# refuses <label> <output file> <message> <command...>: the command prints the
# message and writes nothing to the file, whatever its exit code is.
refuses() {
  label="$1"; out="$2"; message="$3"; shift 3
  rm -f "$out"
  "$@" > tool.log 2>&1 || true
  [ ! -s "$out" ] || fail "$label: $(basename "$1") wrote $out"
  contains "$(cat tool.log)" "$message" || { cat tool.log >&2; fail "$label: $(basename "$1") does not print '$message'"; }
}

# encode <label> <image> <jpeg file> <option>...
encode() {
  label="$1"; image="$2"; jpeg="$3"; shift 3
  run "$label" "$jpeg" "$ISO_JPEG" "$@" "$image" "$jpeg"
}

# decode <label> <jpeg file> <image>
decode() {
  run "$1" "$3" "$ISO_JPEG" "$2" "$3"
}

# bytes_of <file>: the bytes of the file in hexadecimal, each one after a space.
bytes_of() {
  printf ' '
  od -An -v -tx1 "$1" | tr -s ' \r\n' ' '
}

# expect_bytes <file> <what> <bytes>: the file holds the bytes, given as
# bytes_of prints them. They are searched for byte by byte: FF is followed by
# 00 in the entropy-coded data of a scan, so the two bytes of a marker are a
# marker.
expect_bytes() {
  contains "$(bytes_of "$1")" " $3 " || fail "$1: no $2 ($3)"
}

# frame <marker> <bits> [<height>]: the start of the frame header of an image
# of three components: marker, length, sample precision, height, width and
# number of components.
frame() {
  printf 'ff %s 00 11 %02x 00 %02x 00 %02x 03' "$1" "$2" "${3:-$HEIGHT}" "$WIDTH"
}

# largest_difference <image> <image> <bytes per sample>: prints the largest
# difference between the samples both PPM files end with.
largest_difference() {
  count=$((WIDTH * HEIGHT * 3 * $3))
  tail -c "$count" "$1" | od -An -v -tu1 > expected.txt
  tail -c "$count" "$2" | od -An -v -tu1 > actual.txt
  awk -v size="$3" '
    FNR == 1 { input++; count = 0 }
    {
      for (i = 1; i <= NF; i++) {
        if (input == 1) expected[count++] = $i; else actual[count++] = $i
      }
    }
    END {
      max = 0
      for (i = 0; i < count; i += size) {
        a = 0; b = 0
        for (j = 0; j < size; j++) { a = a * 256 + expected[i + j]; b = b * 256 + actual[i + j] }
        difference = a - b
        if (difference < 0) difference = -difference
        if (difference > max) max = difference
      }
      print max
    }' expected.txt actual.txt
}

# expect_image <decoded image> <source image> <maximum> <tolerance>: the decoded
# file is a PPM file of the size and of the maximum value of the source, whose
# samples are the ones of the source within the tolerance.
expect_image() {
  decoded="$1"; source="$2"; maximum="$3"; tolerance="$4"
  bytes=1
  [ "$maximum" -le 255 ] || bytes=2
  header="P6 $WIDTH $HEIGHT $maximum "
  [ "$(head -c "${#header}" "$decoded" | tr '\n' ' ')" = "$header" ] \
    || fail "$decoded is not a PPM file of ${WIDTH}x$HEIGHT with a maximum of $maximum: $(head -c "${#header}" "$decoded" | tr '\n' ' ')"
  [ "$(($(wc -c < "$decoded")))" -eq $((${#header} + WIDTH * HEIGHT * 3 * bytes)) ] \
    || fail "$decoded does not hold $WIDTH x $HEIGHT x 3 samples of $bytes byte(s): $(($(wc -c < "$decoded"))) bytes"
  difference="$(largest_difference "$source" "$decoded" "$bytes")"
  [ "$difference" -le "$tolerance" ] \
    || fail "$decoded: a sample is $difference away from $source, more than $tolerance"
  ok "$decoded: ${WIDTH}x$HEIGHT, maximum $maximum, at most $difference away from the source"
}

# roundtrip <name> <bits> <tolerance> <option>...: rgb<bits>.ppm is encoded to
# <name>.jpg with the options and decoded back to <name>.ppm.
roundtrip() {
  name="$1"; bits="$2"; tolerance="$3"; shift 3
  encode "$name" "rgb$bits.ppm" "$name.jpg" "$@"
  [ "$(od -An -tx1 -N 2 "$name.jpg" | tr -d ' \r\n')" = "ffd8" ] || fail "$name.jpg does not start with SOI"
  decode "$name" "$name.jpg" "$name.ppm"
  expect_image "$name.ppm" "rgb$bits.ppm" "$(((1 << bits) - 1))" "$tolerance"
}

smoke_test() {
  workdir="smoke-iso-jpeg-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  ISO_JPEG="../$(basename "$ISO_JPEG")"

  # A PNM file with a maximum value of 4095 is encoded with 12-bit samples.
  { printf 'P6\n%d %d\n255\n' "$WIDTH" "$HEIGHT"; gradient 255; } > rgb8.ppm
  { printf 'P6\n%d %d\n4095\n' "$WIDTH" "$HEIGHT"; gradient 4095; } > rgb12.ppm
  [ "$(($(wc -c < rgb8.ppm)))" -eq $((13 + WIDTH * HEIGHT * 3)) ] || fail "rgb8.ppm was not written correctly"
  [ "$(($(wc -c < rgb12.ppm)))" -eq $((14 + WIDTH * HEIGHT * 6)) ] || fail "rgb12.ppm was not written correctly"
  ok "wrote the 8-bit and the 12-bit PPM inputs"

  for bits in 8 12; do
    # Twice what the round-trips lose at quality 85 on this image: a sample is
    # at most 18 away from its source with 8 bits and 23 with 12 bits, and 72
    # with 12 bits once the chroma is subsampled.
    case "$bits" in
      8) tolerance=36; subsampled_tolerance=36 ;;
      12) tolerance=48; subsampled_tolerance=144 ;;
    esac

    msg "$bits bits: arithmetic coding, sequential (-q 85 -a)"
    roundtrip "arithmetic$bits" "$bits" "$tolerance" -q 85 -a
    expect_bytes "arithmetic$bits.jpg" "SOF9 frame of $bits bits" "$(frame c9 "$bits")"
    ok "arithmetic$bits.jpg has an SOF9 frame of $bits bits"

    msg "$bits bits: arithmetic coding, progressive (-q 85 -a -v)"
    roundtrip "arithmetic-progressive$bits" "$bits" "$tolerance" -q 85 -a -v
    expect_bytes "arithmetic-progressive$bits.jpg" "SOF10 frame of $bits bits" "$(frame ca "$bits")"
    ok "arithmetic-progressive$bits.jpg has an SOF10 frame of $bits bits"

    msg "$bits bits: Huffman coding, optimized tables (-q 85 -h)"
    roundtrip "huffman$bits" "$bits" "$tolerance" -q 85 -h
    expect_bytes "huffman$bits.jpg" "SOF1 frame of $bits bits" "$(frame c1 "$bits")"
    expect_bytes "huffman$bits.jpg" "DHT marker" "ff c4"
    ok "huffman$bits.jpg has an SOF1 frame of $bits bits and Huffman tables"

    # The three files hold the same quantized coefficients, coded in three
    # ways: what the arithmetic decoder reads is what the Huffman decoder reads.
    cmp -s "arithmetic$bits.ppm" "huffman$bits.ppm" \
      || fail "$bits bits: the arithmetic and the Huffman files do not decode to the same samples"
    cmp -s "arithmetic-progressive$bits.ppm" "huffman$bits.ppm" \
      || fail "$bits bits: the progressive arithmetic and the Huffman files do not decode to the same samples"
    ok "$bits bits: the three files decode to the same samples"

    msg "$bits bits: other options"
    roundtrip "restart$bits" "$bits" "$tolerance" -q 85 -a -z 2
    expect_bytes "restart$bits.jpg" "DRI marker of 2 MCUs" "ff dd 00 04 00 02"
    expect_bytes "restart$bits.jpg" "RST0 marker" "ff d0"
    ok "-z 2: a restart interval of 2 MCUs"

    # The height of the frame header is 0: the DNL marker gives it.
    roundtrip "dnl$bits" "$bits" "$tolerance" -q 85 -a -n
    expect_bytes "dnl$bits.jpg" "SOF9 frame without a height" "$(frame c9 "$bits" 0)"
    expect_bytes "dnl$bits.jpg" "DNL marker of $HEIGHT lines" "$(printf 'ff dc 00 04 00 %02x' "$HEIGHT")"
    ok "-n: the height is in a DNL marker"

    roundtrip "rgb-components$bits" "$bits" "$tolerance" -q 85 -a -c
    if cmp -s "rgb-components$bits.jpg" "arithmetic$bits.jpg"; then fail "-c changes nothing"; fi
    ok "-c: no color transformation"

    roundtrip "subsampled$bits" "$bits" "$subsampled_tolerance" -q 85 -h -s 1x1,2x2,2x2
    expect_bytes "subsampled$bits.jpg" "SOF1 frame of 2x2, 1x1 and 1x1 sampling factors" \
      "$(frame c1 "$bits") 00 22 00 01 11 00 02 11 00"
    ok "-s 1x1,2x2,2x2: 4:2:0 subsampling"

    roundtrip "hierarchical$bits" "$bits" "$tolerance" -q 85 -h -y 2
    expect_bytes "hierarchical$bits.jpg" "DHP marker" "ff de"
    ok "-y 2: hierarchical coding"
  done

  # A failed conversion leaves no file to mistake for a result.
  msg "failures"
  refuses "a PPM file as a JPEG file" not-jpeg.ppm "reading a JPEG file failed" "$ISO_JPEG" rgb8.ppm not-jpeg.ppm
  ok "a file that is not a JPEG file is not decoded"
  refuses "a missing input" missing.jpg "unable to open the input file" "$ISO_JPEG" -q 85 missing.ppm missing.jpg
  ok "a missing input is not encoded"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$ISO_JPEG"
    ;;
esac

case "$MODE" in
  run|all)
    msg "usage"
    assert_usage
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
