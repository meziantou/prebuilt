#!/usr/bin/env bash
#
# Verifies mozjpeg-cjpeg and mozjpeg-jpegtran, the cjpeg and jpegtran of
# mozjpeg built by scripts/build-mozjpeg.sh.
#
#   bash scripts/verify-mozjpeg.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertions plus smoke tests of what the tools are published
#         for (must run on the target platform)
#   all   both (default)
#
# The inputs are a PPM file written with printf and PNG files written by
# scripts/png-writer.sh. A JPEG file is valid when its markers lead from SOI
# to EOI, through a frame header and scans, and jpegtran reads it without a
# warning: jpegtran decodes all the entropy-coded data, and exits with 2 after
# a warning (corrupt data, a premature end of file).
#
# What a caller of the tools has to know, and what this script checks:
# - cjpeg reads JPEG files: it decodes them to pixels and encodes these again
#   with its options (mozjpeg builds without JPEG_RAW_READER), so the
#   quantization tables of the output are the ones of -quality, and it copies
#   the COM and APPn markers (EXIF, ICC profile, XMP) of the input.
# - cjpeg exits with 0 after a warning of its JPEG reader, a truncated JPEG
#   input among them, even with -strict; jpegtran exits with 2.
#
# MOZJPEG_VERSION comes from the environment (see .github/workflows/ci.yml);
# without it, the version check is skipped.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CJPEG="./mozjpeg-cjpeg-$TARGET$EXE"
JPEGTRAN="./mozjpeg-jpegtran-$TARGET$EXE"
for bin in "$CJPEG" "$JPEGTRAN"; do
  [ -f "$bin" ] || { echo "missing $bin" >&2; exit 1; }
  chmod +x "$bin" 2>/dev/null || true
done

# The samples are written byte by byte with printf.
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

# shellcheck source=verify-common.sh
. "$SCRIPT_DIR/verify-common.sh"
# shellcheck source=png-writer.sh
. "$SCRIPT_DIR/png-writer.sh"

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

# <tool> -version prints "mozjpeg version 4.1.5 (build 20261121)".
assert_version() {
  for bin in "$CJPEG" "$JPEGTRAN"; do
    banner="$("$bin" -version 2>&1 | head -n 1 | tr -d '\r')" || fail "$bin -version failed: $banner"
    if [ -z "$MOZJPEG_VERSION" ]; then
      echo "  MOZJPEG_VERSION is not set; skipping the version check of $bin ($banner)"
      continue
    fi
    case "$banner" in
      "mozjpeg version $MOZJPEG_VERSION (build "*) ok "$bin reports mozjpeg $MOZJPEG_VERSION ($banner)" ;;
      *) fail "$bin does not report mozjpeg $MOZJPEG_VERSION: $banner" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# JPEG files
# ---------------------------------------------------------------------------

# jpeg_info <file>: prints "<frame> <width>x<height>x<components>, <scans>
# scans: <marker> <marker>...", the markers up to EOI, or what is wrong.
jpeg_info() {
  od -An -v -tu1 "$1" | awk '
    { for (i = 1; i <= NF; i++) byte[count++] = $i }
    function name(m) {
      if (m >= 192 && m <= 207 && m != 196 && m != 200 && m != 204) return "SOF" (m - 192)
      if (m == 196) return "DHT"
      if (m == 219) return "DQT"
      if (m == 221) return "DRI"
      if (m == 218) return "SOS"
      if (m == 217) return "EOI"
      if (m == 254) return "COM"
      if (m >= 224 && m <= 239) return "APP" (m - 224)
      return sprintf("FF%02X", m)
    }
    END {
      if (count < 4 || byte[0] != 255 || byte[1] != 216) { print "no SOI"; exit }
      frame = "no frame"; scans = 0; markers = "SOI"; p = 2
      while (1) {
        if (p + 1 >= count) { print "no EOI: " markers; exit }
        if (byte[p] != 255) { print "no marker at offset " p ": " markers; exit }
        m = byte[p + 1]
        if (m == 255) { p++; continue }
        markers = markers " " name(m)
        if (m == 217) break
        size = byte[p + 2] * 256 + byte[p + 3]
        if (name(m) ~ /^SOF/) {
          frame = name(m) " " (byte[p + 7] * 256 + byte[p + 8]) "x" (byte[p + 5] * 256 + byte[p + 6]) "x" byte[p + 9]
        }
        p += 2 + size
        if (m == 218) {
          # The entropy-coded data of the scan: up to a marker that is not a
          # stuffed 0xFF (FF 00) or a restart marker (FF D0 to FF D7).
          scans++
          while (p + 1 < count && !(byte[p] == 255 && byte[p + 1] != 0 && (byte[p + 1] < 208 || byte[p + 1] > 215))) p++
        }
      }
      if (p + 2 != count) { print "data after EOI: " markers; exit }
      print frame ", " scans " scans: " markers
    }'
}

# jpeg_tables <file>: the bytes of the DQT segments of the file, in hexadecimal.
jpeg_tables() {
  od -An -v -tu1 "$1" | awk '
    { for (i = 1; i <= NF; i++) byte[count++] = $i }
    END {
      p = 2
      while (p + 3 < count && byte[p] == 255 && byte[p + 1] != 218 && byte[p + 1] != 217) {
        size = byte[p + 2] * 256 + byte[p + 3]
        if (byte[p + 1] == 219) for (i = p; i < p + 2 + size; i++) printf "%02x", byte[i]
        p += 2 + size
      }
      print ""
    }'
}

# expect_jpeg <label> <file> <frame>: the file is a valid JPEG file of the
# frame ("SOF2 48x32x3"), which jpegtran reads without a warning.
expect_jpeg() {
  label="$1"; file="$2"; expected_frame="$3"
  info="$(jpeg_info "$file")"
  case "$info" in
    "$expected_frame, "*" scans: SOI "*" EOI") ;;
    *) fail "$label: $file is not a valid JPEG file of $expected_frame: $info" ;;
  esac
  rm -f check.jpg
  "$JPEGTRAN" -copy all -outfile check.jpg "$file" > check.log 2>&1 \
    || { cat check.log >&2; fail "$label: jpegtran does not read $file without a warning"; }
  [ -s check.jpg ] || fail "$label: jpegtran wrote nothing for $file"
  ok "$label: $info"
}

# run <label> <output file> <command...>: the command succeeds, without a
# message, and writes the file, which is removed first.
run() {
  label="$1"; out="$2"; shift 2
  rm -f "$out"
  "$@" > tool.log 2>&1 || { cat tool.log >&2; fail "$label: $(basename "$1") failed"; }
  [ ! -s tool.log ] || { cat tool.log >&2; fail "$label: $(basename "$1") printed a warning"; }
  [ -s "$out" ] || fail "$label: $(basename "$1") wrote no $out"
}

# refuses <label> <message> <command...>: the command fails with the message.
refuses() {
  label="$1"; message="$2"; shift 2
  status=0
  "$@" > tool.log 2>&1 || status=$?
  [ "$status" -ne 0 ] || { cat tool.log >&2; fail "$label: $(basename "$1") succeeded"; }
  contains "$(cat tool.log)" "$message" || { cat tool.log >&2; fail "$label: $(basename "$1") does not print '$message'"; }
  ok "$label: exit code $status, '$message'"
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

WIDTH=48
HEIGHT=32

# gradient <samples per pixel>: prints the samples of a $WIDTH x $HEIGHT image,
# a gradient with some texture so that the blocks have AC coefficients, as RGB
# (3), RGBA (4), or gray (1). With a filter byte before each row, for PNG.
gradient() {
  per_pixel="$1"; filter="$2"
  y=0
  while [ "$y" -lt "$HEIGHT" ]; do
    row=""
    [ -z "$filter" ] || row='\000'
    x=0
    while [ "$x" -lt "$WIDTH" ]; do
      texture=$((x * y % 7 * 4))
      r=$((x * 255 / (WIDTH - 1) * 7 / 8 + texture))
      g=$((y * 255 / (HEIGHT - 1) * 7 / 8 + texture))
      b=$(((x + y) * 255 / (WIDTH + HEIGHT - 2) * 7 / 8 + texture))
      case "$per_pixel" in
        1) printf -v pixel '\\%03o' "$g" ;;
        3) printf -v pixel '\\%03o\\%03o\\%03o' "$r" "$g" "$b" ;;
        4) printf -v pixel '\\%03o\\%03o\\%03o\\%03o' "$r" "$g" "$b" $((x * 255 / (WIDTH - 1))) ;;
      esac
      row="$row$pixel"
      x=$((x + 1))
    done
    # shellcheck disable=SC2059
    printf "$row"
    y=$((y + 1))
  done
}

smoke_test() {
  workdir="smoke-mozjpeg-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  CJPEG="../$(basename "$CJPEG")"
  JPEGTRAN="../$(basename "$JPEGTRAN")"

  { printf 'P6\n%d %d\n255\n' "$WIDTH" "$HEIGHT"; gradient 3; } > rgb.ppm
  [ "$(file_size rgb.ppm)" -eq $((13 + WIDTH * HEIGHT * 3)) ] || fail "rgb.ppm was not written correctly"
  gradient 3 png > rgb.raw
  write_png rgb.png "$WIDTH" "$HEIGHT" 8 2 rgb.raw
  gradient 4 png > rgba.raw
  write_png rgba.png "$WIDTH" "$HEIGHT" 8 6 rgba.raw
  gradient 1 png > gray.raw
  write_png gray.png "$WIDTH" "$HEIGHT" 8 0 gray.raw
  ok "wrote the PPM and PNG inputs"

  frame="SOF2 ${WIDTH}x${HEIGHT}x3"

  msg "cjpeg -quality 82"
  # Progressive with optimized scans is the default of mozjpeg.
  run "a PPM input" ppm.jpg "$CJPEG" -quality 82 -outfile ppm.jpg rgb.ppm
  expect_jpeg "a PPM input" ppm.jpg "$frame"
  run "a PNG input" png.jpg "$CJPEG" -quality 82 -outfile png.jpg rgb.png
  expect_jpeg "a PNG input" png.jpg "$frame"
  # The same pixels, read by libpng instead of the PPM reader.
  same_file "the PNG and the PPM inputs encode to the same file" png.jpg ppm.jpg
  # cjpeg drops the alpha channel.
  run "a PNG input with an alpha channel" rgba.jpg "$CJPEG" -quality 82 -outfile rgba.jpg rgba.png
  expect_jpeg "a PNG input with an alpha channel" rgba.jpg "$frame"
  same_file "the alpha channel is dropped" rgba.jpg png.jpg
  run "a grayscale PNG input" gray.jpg "$CJPEG" -quality 82 -outfile gray.jpg gray.png
  expect_jpeg "a grayscale PNG input" gray.jpg "SOF2 ${WIDTH}x${HEIGHT}x1"
  run "standard input and output" stdout.jpg sh -c '"$1" -quality 82 < "$2" > "$3"' sh "$CJPEG" rgb.ppm stdout.jpg
  same_file "standard input and output" stdout.jpg ppm.jpg
  run "-baseline" baseline.jpg "$CJPEG" -quality 82 -baseline -outfile baseline.jpg rgb.ppm
  expect_jpeg "-baseline" baseline.jpg "SOF0 ${WIDTH}x${HEIGHT}x3"

  msg "cjpeg, a JPEG input"
  # A JPEG file of quality 95 with a COM marker, as an editor writes one:
  # cjpeg decodes it, and encodes the pixels again with the tables of
  # -quality 82, and with the COM marker.
  run "the source" q95.jpg "$CJPEG" -quality 95 -outfile q95.jpg rgb.ppm
  comment="prebuilt smoke test"
  { printf '\377\330\377\376'; printf "\\$(printf '%03o' $(((${#comment} + 2) >> 8)))\\$(printf '%03o' $(((${#comment} + 2) & 255)))"
    printf '%s' "$comment"; tail -c +3 q95.jpg; } > source.jpg
  expect_jpeg "the source, with a COM marker" source.jpg "$frame"
  run "a JPEG input" reencoded.jpg "$CJPEG" -quality 82 -outfile reencoded.jpg source.jpg
  expect_jpeg "a JPEG input" reencoded.jpg "$frame"
  [ "$(jpeg_tables reencoded.jpg)" = "$(jpeg_tables ppm.jpg)" ] \
    || fail "a JPEG input: the quantization tables are not the ones of -quality 82"
  [ "$(jpeg_tables reencoded.jpg)" != "$(jpeg_tables source.jpg)" ] \
    || fail "a JPEG input: the quantization tables are the ones of the source"
  ok "a JPEG input is encoded again with the quantization tables of -quality 82"
  contains "$(jpeg_info reencoded.jpg)" " COM " && grep -a -q -F "$comment" reencoded.jpg \
    || fail "a JPEG input: the COM marker of the source is not copied: $(jpeg_info reencoded.jpg)"
  ok "a JPEG input: its COM marker is copied"

  msg "jpegtran -copy none -optimize -progressive"
  run "jpegtran" optimized.jpg "$JPEGTRAN" -copy none -optimize -progressive -outfile optimized.jpg source.jpg
  expect_jpeg "jpegtran" optimized.jpg "$frame"
  if contains "$(jpeg_info optimized.jpg)" " COM "; then fail "-copy none: optimized.jpg has a COM marker"; fi
  ok "-copy none: no COM marker"
  # Lossless: the file and its source have the same coefficients, as the same
  # baseline file (-revert: the defaults of libjpeg) shows.
  run "jpegtran -revert of the source" source-baseline.jpg "$JPEGTRAN" -revert -copy none -optimize -outfile source-baseline.jpg source.jpg
  run "jpegtran -revert of the result" optimized-baseline.jpg "$JPEGTRAN" -revert -copy none -optimize -outfile optimized-baseline.jpg optimized.jpg
  expect_jpeg "jpegtran -revert" source-baseline.jpg "SOF0 ${WIDTH}x${HEIGHT}x3"
  same_file "jpegtran keeps the coefficients" optimized-baseline.jpg source-baseline.jpg
  run "-copy all" all.jpg "$JPEGTRAN" -copy all -outfile all.jpg source.jpg
  grep -a -q -F "$comment" all.jpg || fail "-copy all: the COM marker is not copied"
  ok "-copy all: the COM marker is copied"
  run "standard input and output" jpegtran-stdout.jpg sh -c '"$1" -copy none -optimize -progressive < "$2" > "$3"' sh "$JPEGTRAN" source.jpg jpegtran-stdout.jpg
  same_file "standard input and output" jpegtran-stdout.jpg optimized.jpg

  msg "failures"
  printf 'not an image' > not-image.txt
  refuses "cjpeg, a file that is not an image" "can't read the image" "$CJPEG" -outfile not-image.jpg not-image.txt
  refuses "jpegtran, a file that is not a JPEG file" "Not a JPEG file" "$JPEGTRAN" -outfile not-jpeg.jpg rgb.png
  head -c $(($(file_size source.jpg) / 2)) source.jpg > truncated.jpg
  status=0
  "$JPEGTRAN" -outfile truncated-out.jpg truncated.jpg > tool.log 2>&1 || status=$?
  [ "$status" -eq 2 ] || { cat tool.log >&2; fail "jpegtran, a truncated file: exit code $status, not 2"; }
  ok "jpegtran, a truncated file: exit code 2 (a warning)"
  # The JPEG reader of cjpeg has an error manager of its own, which -strict
  # does not make strict: cjpeg prints the warning, and succeeds.
  for strict in "" -strict; do
    status=0
    rm -f truncated-out.jpg
    # shellcheck disable=SC2086
    "$CJPEG" $strict -outfile truncated-out.jpg truncated.jpg > tool.log 2>&1 || status=$?
    [ "$status" -eq 0 ] || { cat tool.log >&2; fail "cjpeg $strict, a truncated JPEG input: exit code $status, not 0"; }
    contains "$(cat tool.log)" "Premature end of JPEG file" || { cat tool.log >&2; fail "cjpeg $strict, a truncated JPEG input: no warning"; }
    [ -s truncated-out.jpg ] || fail "cjpeg $strict, a truncated JPEG input: no output file"
    ok "cjpeg${strict:+ $strict}, a truncated JPEG input: a warning, exit code 0, an output file"
  done

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$CJPEG"
    assert_linkage "$JPEGTRAN"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    assert_version
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
