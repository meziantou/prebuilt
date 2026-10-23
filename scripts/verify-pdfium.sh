#!/usr/bin/env bash
#
# Verifies the pdfium_test bundle built by scripts/build-pdfium.sh:
# pdfium_test-<target>.tar.gz, with pdfium_test[.exe], fonts/, test_fonts/ and
# LICENSE at its root.
#
#   bash scripts/verify-pdfium.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  bundle layout and linkage assertions only
#   run   build configuration plus smoke tests: rasters (PPM and PNG) with
#         the fonts of the bundle, MD5 output, text extraction, and the same
#         MD5 for two runs (must run on the target platform)
#   all   both (default)
#
# What the smoke tests found out about pdfium_test, and assert:
# - It prints no version: its version is the chromium/<N> branch it is built
#   from. --show-config prints the optional features it is built with, one
#   line, empty for this build (no V8, XFA or Skia).
# - One output format per run: --ppm with --png is refused.
# - The PPM files start with a comment line ("# PDF test render").
# - --md5 prints "MD5:<output file>:<md5 of the pixels>", not the MD5 of the
#   PNG file.
# - --txt writes the text in UTF-32LE, with a byte order mark.
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

ARCHIVE="./pdfium_test-$TARGET.tar.gz"
[ -f "$ARCHIVE" ] || { echo "missing $ARCHIVE" >&2; exit 1; }

# The test files are written byte by byte with printf.
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

BUNDLE="./pdfium-verify-$TARGET"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
tar -xzf "$ARCHIVE" -C "$BUNDLE"
PDFIUM_TEST="$BUNDLE/pdfium_test$EXE"

# ---------------------------------------------------------------------------
# Layout and linkage
# ---------------------------------------------------------------------------

assert_layout() {
  [ -f "$PDFIUM_TEST" ] || fail "$ARCHIVE has no pdfium_test$EXE at its root"
  [ -f "$BUNDLE/LICENSE" ] || fail "$ARCHIVE has no LICENSE"
  [ -f "$BUNDLE/fonts/ahem/Ahem.ttf" ] || fail "$ARCHIVE has no fonts/ahem/Ahem.ttf"
  [ -d "$BUNDLE/fonts/symbolneu" ] || fail "$ARCHIVE has no fonts/symbolneu"
  for font in Arimo-Regular.ttf Cousine-Regular.ttf Tinos-Regular.ttf; do
    [ -f "$BUNDLE/test_fonts/$font" ] || fail "$ARCHIVE has no test_fonts/$font"
  done
  ok "$ARCHIVE has pdfium_test$EXE, LICENSE and the fonts of the pixel tests"
}

# The llvm-mingw objdump of the other jobs, or the LLVM of the Windows runner.
find_objdump() {
  for candidate in x86_64-w64-mingw32-objdump objdump llvm-objdump "/c/Program Files/LLVM/bin/llvm-objdump"; do
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
      # Linked against the glibc of the Chromium sysroot: only glibc libraries.
      # readelf reads the binaries of either architecture.
      needed="$(readelf -d "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort -u)"
      [ -n "$needed" ] || fail "could not list the libraries of $bin"
      for library in $needed; do
        case "$library" in
          libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|librt.so.1|ld-linux-x86-64.so.2|ld-linux-aarch64.so.1) ;;
          *) fail "$bin needs a library that is not part of glibc: $library" ;;
        esac
      done
      ok "$bin needs only glibc ($(echo $needed | tr ' ' ','))"
      ;;
    osx-arm64)
      deps="$(otool -L "$bin" | tail -n +2 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*(.*$//' \
              | grep -v '^/usr/lib/' | grep -v '^/System/Library/' || true)"
      [ -z "$deps" ] || fail "$bin links non-system dylibs: $deps"
      ok "$bin links only system dylibs"
      ;;
    win-*)
      objdump="$(find_objdump)" || fail "no objdump or llvm-objdump to list the imports of $bin"
      imports="$("$objdump" -p "$bin" | sed -n 's/^[[:space:]]*DLL Name: //p' | tr 'A-Z' 'a-z' | tr -d '\r' | sort -u)"
      [ -n "$imports" ] || fail "could not list the imports of $bin"
      for dll in $imports; do
        # DLLs of Windows itself: the static CRT leaves no vcruntime or ucrt
        # DLL behind.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|dbghelp.dll|winmm.dll|version.dll|ws2_32.dll|shlwapi.dll|bcrypt.dll|bcryptprimitives.dll|api-ms-win-*) ;;
          *) fail "$bin imports a DLL that is not part of Windows: $dll" ;;
        esac
      done
      ok "$bin imports only system DLLs ($(echo $imports | tr ' ' ','))"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# PDF writer
# ---------------------------------------------------------------------------

file_size() { echo $(($(wc -c < "$1"))); }

# pdf_begin <file>, then pdf_object / pdf_stream for objects 1, 2, ... in
# order, then pdf_end: a classic cross-reference table with the right offsets.
pdf_begin() {
  PDF_FILE="$1"
  PDF_OFFSETS=""
  PDF_COUNT=0
  printf '%%PDF-1.7\n%%\342\343\317\323\n' > "$PDF_FILE"
}

# pdf_object <dictionary or value>
pdf_object() {
  PDF_COUNT=$((PDF_COUNT + 1))
  PDF_OFFSETS="$PDF_OFFSETS $(file_size "$PDF_FILE")"
  printf '%d 0 obj\n%s\nendobj\n' "$PDF_COUNT" "$1" >> "$PDF_FILE"
}

# pdf_stream <dictionary entries> <data file>
pdf_stream() {
  PDF_COUNT=$((PDF_COUNT + 1))
  PDF_OFFSETS="$PDF_OFFSETS $(file_size "$PDF_FILE")"
  printf '%d 0 obj\n<< %s /Length %d >>\nstream\n' "$PDF_COUNT" "$1" "$(file_size "$2")" >> "$PDF_FILE"
  cat "$2" >> "$PDF_FILE"
  printf '\nendstream\nendobj\n' >> "$PDF_FILE"
}

pdf_end() {
  xref="$(file_size "$PDF_FILE")"
  {
    printf 'xref\n0 %d\n0000000000 65535 f \n' $((PDF_COUNT + 1))
    for offset in $PDF_OFFSETS; do
      printf '%010d 00000 n \n' "$offset"
    done
    printf 'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' $((PDF_COUNT + 1)) "$xref"
  } >> "$PDF_FILE"
}

# A 200x100 page with a red rectangle, a line of Helvetica text, and an
# uncompressed 16x16 RGB image (a red and a blue half).
write_sample_pdf() {
  printf 'q 1 0 0 rg 10 10 80 80 re f Q\nBT /F1 12 Tf 100 50 Td (Hello PDF) Tj ET\nq 32 0 0 32 160 60 cm /Im1 Do Q\n' > content.bin
  : > image.bin
  row=0
  while [ "$row" -lt 16 ]; do
    column=0
    while [ "$column" -lt 16 ]; do
      if [ "$row" -lt 8 ]; then printf '\377\000\000' >> image.bin; else printf '\000\000\377' >> image.bin; fi
      column=$((column + 1))
    done
    row=$((row + 1))
  done
  [ "$(file_size image.bin)" -eq 768 ] || fail "image.bin was not written correctly"

  pdf_begin "$1"
  pdf_object '<< /Type /Catalog /Pages 2 0 R >>'
  pdf_object '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
  pdf_object '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> >>'
  pdf_stream '' content.bin
  pdf_object '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
  pdf_stream '/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8' image.bin
  pdf_end
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# run <description> <command...>: runs a command that must succeed, with its
# output in tool.log.
run() {
  description="$1"; shift
  if ! "$@" > tool.log 2>&1; then
    cat tool.log >&2
    fail "$description"
  fi
  tr -d '\r' < tool.log > tool.log.tmp && mv tool.log.tmp tool.log
}

# pixel <ppm file> <x> <y>: "r g b" of a pixel of a 200x100 binary PPM file,
# whose header is what is before the 200 x 100 x 3 bytes of pixels.
pixel() {
  header=$(($(file_size "$1") - 200 * 100 * 3))
  od -An -tu1 -j $((header + ($3 * 200 + $2) * 3)) -N3 "$1" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

# assert_pixel <ppm file> <x> <y> <r> <g> <b> <tolerance>
assert_pixel() {
  value="$(pixel "$1" "$2" "$3")"
  set -- "$@" $value
  for channel in 1 2 3; do
    eval "expected=\${$((channel + 3))}; actual=\${$((channel + 7))}"
    difference=$((actual - expected))
    [ "$difference" -lt 0 ] && difference=$((-difference))
    [ "$difference" -le "$7" ] || fail "pixel ($2, $3) of $1 is ($value), expected ($4 $5 $6)"
  done
}

# dark_pixels <ppm file> <x0> <y0> <x1> <y1>: the number of pixels of the
# rectangle whose red channel is below 128.
dark_pixels() {
  header=$(($(file_size "$1") - 200 * 100 * 3))
  count=0
  y="$3"
  while [ "$y" -lt "$5" ]; do
    index=0
    for value in $(od -An -tu1 -v -j $((header + ($y * 200 + $2) * 3)) -N $((($4 - $2) * 3)) "$1"); do
      index=$((index + 1))
      if [ $((index % 3)) -eq 1 ] && [ "$value" -lt 128 ]; then count=$((count + 1)); fi
    done
    y=$((y + 1))
  done
  echo "$count"
}

assert_config() {
  # Empty: no V8, no XFA, no Skia.
  run "pdfium_test --show-config" "$PDFIUM_TEST" --show-config
  [ -z "$(tr -d '\n' < tool.log)" ] || fail "pdfium_test is built with optional features: $(cat tool.log)"
  ok "pdfium_test is built without V8, XFA and Skia"
}

smoke_test() {
  rm -rf pdfium-smoke
  mkdir pdfium-smoke
  cd pdfium-smoke
  PDFIUM_TEST="../$PDFIUM_TEST"
  FONTS="../$BUNDLE/test_fonts"
  write_sample_pdf sample.pdf
  # The options of the pixel tests (testing/tools/test_runner.py).
  set -- --time=1399672130 --font-dir="$FONTS" --croscore-font-names

  msg "PPM"
  run "pdfium_test --ppm" "$PDFIUM_TEST" --ppm "$@" sample.pdf
  [ -f sample.pdf.0.ppm ] || fail "pdfium_test wrote no sample.pdf.0.ppm"
  [ "$(head -c 3 sample.pdf.0.ppm | od -An -c | tr -d ' ')" = 'P6\n' ] || fail "sample.pdf.0.ppm is not a binary PPM file"
  contains "$(head -c 40 sample.pdf.0.ppm)" "200 100" || fail "sample.pdf.0.ppm is not 200x100"
  assert_pixel sample.pdf.0.ppm 50 50 255 0 0 0
  assert_pixel sample.pdf.0.ppm 5 5 255 255 255 0
  assert_pixel sample.pdf.0.ppm 176 12 255 0 0 0
  assert_pixel sample.pdf.0.ppm 176 36 0 0 255 0
  # "Hello PDF", in the Arimo of the test fonts for Helvetica.
  dark="$(dark_pixels sample.pdf.0.ppm 100 48 156 60)"
  [ "$dark" -gt 15 ] || fail "the text of sample.pdf.0.ppm is not drawn ($dark dark pixels)"
  ok "--ppm draws the rectangle, the image and the text with the test fonts"

  msg "PNG and MD5"
  run "pdfium_test --png --md5" "$PDFIUM_TEST" --png --md5 "$@" sample.pdf
  header="$(od -An -tu1 -N24 sample.pdf.0.png | tr -s ' \n' ' ' | sed -e 's/^ //' -e 's/ $//')"
  [ "$header" = "137 80 78 71 13 10 26 10 0 0 0 13 73 72 68 82 0 0 0 200 0 0 0 100" ] \
    || fail "sample.pdf.0.png is not a 200x100 PNG file: $header"
  md5_line="$(grep '^MD5:' tool.log || true)"
  case "$md5_line" in
    MD5:sample.pdf.0.png:[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) cat tool.log >&2; fail "pdfium_test --md5 does not print the MD5 of sample.pdf.0.png" ;;
  esac
  [ "${#md5_line}" -eq $((21 + 32)) ] || fail "unexpected MD5 line: $md5_line"
  first_md5="$md5_line"
  run "pdfium_test --png --md5 (again)" "$PDFIUM_TEST" --png --md5 "$@" sample.pdf
  [ "$(grep '^MD5:' tool.log)" = "$first_md5" ] || fail "two runs give different MD5s: $first_md5, $(grep '^MD5:' tool.log)"
  ok "--png writes a 200x100 PNG file, and --md5 gives the same MD5 twice"

  msg "text"
  run "pdfium_test --txt" "$PDFIUM_TEST" --txt sample.pdf
  # UTF-32LE with a byte order mark: FF FE 00 00, then H 00 00 00 e 00 00 00 ...
  text="$(od -An -tu1 -N20 sample.pdf.0.txt | tr -s ' \n' ' ' | sed -e 's/^ //' -e 's/ $//')"
  [ "$text" = "255 254 0 0 72 0 0 0 101 0 0 0 108 0 0 0 108 0 0 0" ] || fail "sample.pdf.0.txt does not start with 'Hell' in UTF-32LE: $text"
  ok "--txt extracts the text"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

msg "bundle ($TARGET)"
assert_layout

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$PDFIUM_TEST"
    ;;
esac

case "$MODE" in
  run|all)
    msg "configuration"
    assert_config
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
