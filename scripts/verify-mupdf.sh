#!/usr/bin/env bash
#
# Verifies the mutool built by scripts/build-mupdf.sh.
#
#   bash scripts/verify-mupdf.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertion plus smoke tests of what mutool is published for:
#         rasters (draw), text extraction, object dumps (show), rewriting
#         (clean), encryption and the image decoders (must run on the target
#         platform)
#   all   both (default)
#
# What the smoke tests found out about mutool, and assert:
# - A non-embedded Helvetica is drawn with the built-in fonts: the rasters do
#   not depend on the fonts of the machine.
# - `mutool draw` prints "page <file> <number>" on stderr for every page.
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

MUTOOL="./mutool-$TARGET$EXE"
[ -f "$MUTOOL" ] || { echo "missing $MUTOOL" >&2; exit 1; }
chmod +x "$MUTOOL" 2>/dev/null || true

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

# ---------------------------------------------------------------------------
# Linkage
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
        # else means a dependency leaked in dynamically.
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
}

assert_version() {
  # "mutool version 1.28.5", on stderr.
  output="$("$MUTOOL" -v 2>&1 | tr -d '\r')"
  if [ -z "$MUPDF_VERSION" ]; then
    echo "  MUPDF_VERSION is not set; skipping the version check: $output"
  else
    [ "$output" = "mutool version $MUPDF_VERSION" ] || fail "mutool does not report version $MUPDF_VERSION: $output"
    ok "mutool reports version $MUPDF_VERSION"
  fi
}

# pixel <ppm file> <x> <y>: "r g b" of a pixel of a 200x100 binary PPM file
# drawn at 72 dpi, whose header is "P6\n200 100\n255\n" (15 bytes).
pixel() {
  od -An -tu1 -j $((15 + ($3 * 200 + $2) * 3)) -N3 "$1" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
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
  count=0
  y="$3"
  while [ "$y" -lt "$5" ]; do
    for value in $(od -An -tu1 -v -j $((15 + ($y * 200 + $2) * 3)) -N $((($4 - $2) * 3)) "$1"); do
      index=$((${index:-0} + 1))
      if [ $((index % 3)) -eq 1 ] && [ "$value" -lt 128 ]; then count=$((count + 1)); fi
    done
    index=0
    y=$((y + 1))
  done
  echo "$count"
}

assert_ppm_header() {
  [ "$(head -c 15 "$1" | od -An -c | tr -d ' \n')" = 'P6\n200100\n255\n' ] \
    || fail "$1 is not a 200x100 binary PPM file: $(head -c 15 "$1" | od -An -c)"
}

# assert_sample_raster <ppm file> <tolerance>: the red rectangle, the white
# background, the two halves of the image and the text are where sample.pdf
# draws them.
assert_sample_raster() {
  assert_ppm_header "$1"
  assert_pixel "$1" 50 50 255 0 0 0
  assert_pixel "$1" 5 5 255 255 255 0
  assert_pixel "$1" 176 12 255 0 0 "$2"
  assert_pixel "$1" 176 36 0 0 255 "$2"
  # "Hello PDF" is between x = 100 and 155, and y = 50 and 59; drawn with
  # anti-aliasing, about 30 of its pixels are dark at 72 dpi.
  dark="$(dark_pixels "$1" 100 48 156 60)"
  [ "$dark" -gt 15 ] || fail "the text of $1 is not drawn ($dark dark pixels)"
}

smoke_test() {
  rm -rf mupdf-smoke
  mkdir mupdf-smoke
  cd mupdf-smoke
  MUTOOL="../$MUTOOL"
  write_sample_pdf sample.pdf

  msg "draw"
  run "mutool draw PPM" "$MUTOOL" draw -o sample.ppm -r 72 sample.pdf
  contains "$(cat tool.log)" "page sample.pdf 1" || { cat tool.log >&2; fail "mutool draw did not report the page"; }
  assert_sample_raster sample.ppm 0
  ok "draw -r 72 writes the expected raster, text included"

  run "mutool draw PNG" "$MUTOOL" draw -o sample.png -r 72 sample.pdf
  # Signature, then the IHDR chunk: length 13, "IHDR", width 200, height 100.
  header="$(od -An -tu1 -N24 sample.png | tr -s ' \n' ' ' | sed -e 's/^ //' -e 's/ $//')"
  [ "$header" = "137 80 78 71 13 10 26 10 0 0 0 13 73 72 68 82 0 0 0 200 0 0 0 100" ] \
    || fail "sample.png is not a 200x100 PNG file: $header"
  ok "draw writes a 200x100 PNG file"

  run "mutool draw -r 144" "$MUTOOL" draw -o sample-144.png -r 144 sample.pdf
  header="$(od -An -tu1 -j16 -N8 sample-144.png | tr -s ' \n' ' ' | sed -e 's/^ //' -e 's/ $//')"
  [ "$header" = "0 0 1 144 0 0 0 200" ] || fail "sample-144.png is not 400x200: $header"
  ok "draw -r 144 doubles the size"

  msg "text"
  run "mutool draw -F txt" "$MUTOOL" draw -F txt -o sample.txt sample.pdf
  # A form feed ends every page.
  [ "$(tr -d '\r\f' < sample.txt | sed '/^$/d')" = "Hello PDF" ] || fail "the text of sample.pdf is not 'Hello PDF': $(cat sample.txt)"
  run "mutool draw -F stext" "$MUTOOL" draw -F stext -o sample.xml sample.pdf
  contains "$(cat sample.xml)" '<font name="Helvetica" size="12">' || fail "the structured text has no 12pt Helvetica: $(cat sample.xml)"
  ok "txt and stext extract the text"

  msg "show"
  run "mutool show trailer" "$MUTOOL" show sample.pdf trailer
  contains "$(cat tool.log)" "/Root 1 0 R" || { cat tool.log >&2; fail "mutool show trailer has no /Root"; }
  run "mutool show object" "$MUTOOL" show sample.pdf 5
  contains "$(cat tool.log)" "/BaseFont /Helvetica" || { cat tool.log >&2; fail "mutool show 5 is not the font dictionary"; }
  run "mutool show -b" "$MUTOOL" show -b -o content.out sample.pdf 4
  cmp -s content.out content.bin || fail "mutool show -b does not write the content stream"
  ok "show dumps the trailer, an object and a stream"

  msg "clean"
  run "mutool clean" "$MUTOOL" clean -gggg -z sample.pdf clean.pdf
  run "mutool info" "$MUTOOL" info clean.pdf
  contains "$(cat tool.log)" "Pages: 1" || { cat tool.log >&2; fail "clean.pdf does not have one page"; }
  run "mutool draw clean.pdf" "$MUTOOL" draw -o clean.ppm -r 72 clean.pdf
  cmp -s sample.ppm clean.ppm || fail "clean.pdf is not drawn as sample.pdf"
  ok "clean rewrites the file, which is drawn the same"

  msg "encryption"
  for method in rc4-40 rc4-128 aes-128 aes-256; do
    run "mutool clean -E $method" "$MUTOOL" clean -E "$method" -O owner -U user sample.pdf "$method.pdf"
    contains "$(cat "$method.pdf")" "/Encrypt" || fail "$method.pdf has no /Encrypt entry"
    if "$MUTOOL" draw -o refused.ppm "$method.pdf" > tool.log 2>&1; then
      fail "mutool draws $method.pdf without its password"
    fi
    contains "$(cat tool.log)" "cannot authenticate password" || { cat tool.log >&2; fail "mutool does not ask for the password of $method.pdf"; }
    run "mutool draw -p user $method" "$MUTOOL" draw -p user -o "$method.ppm" -r 72 "$method.pdf"
    cmp -s sample.ppm "$method.ppm" || fail "$method.pdf is not drawn as sample.pdf"
    run "mutool draw -p owner $method" "$MUTOOL" draw -p owner -o "$method-owner.ppm" -r 72 "$method.pdf"
    cmp -s sample.ppm "$method-owner.ppm" || fail "$method.pdf is not drawn as sample.pdf with the owner password"
    run "mutool clean -D $method" "$MUTOOL" clean -D -p user "$method.pdf" "$method-decrypted.pdf"
    contains "$(cat "$method-decrypted.pdf")" "/Encrypt" && fail "$method-decrypted.pdf is still encrypted"
    ok "$method: written, refused without a password, drawn with the user and owner passwords, decrypted"
  done

  msg "image codecs"
  # clean recompresses the image with the libjpeg and OpenJPEG MuPDF is built
  # with, and draw decodes it back.
  for codec in "jpeg|DCT" "j2k|JPX"; do
    method="${codec%%|*}"; filter="${codec#*|}"
    run "mutool clean $method" "$MUTOOL" clean --color-image-recompress-method "$method" \
      --recompress-images-when always sample.pdf "$method.pdf"
    run "mutool info -I $method" "$MUTOOL" info -I "$method.pdf"
    contains "$(cat tool.log)" "[ $filter ] 16x16 8bpc" || { cat tool.log >&2; fail "the image of $method.pdf is not $filter"; }
    run "mutool draw $method" "$MUTOOL" draw -o "$method.ppm" -r 72 "$method.pdf"
    assert_sample_raster "$method.ppm" 8
    ok "$method: the image is recompressed as $filter and drawn back"
  done

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$MUTOOL"
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
