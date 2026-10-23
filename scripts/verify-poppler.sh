#!/usr/bin/env bash
#
# Verifies the pdftoppm/pdftotext/pdffonts/pdfinfo/pdfsig set built by
# scripts/build-poppler.sh.
#
#   bash scripts/verify-poppler.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertions plus smoke tests of what the tools are published
#         for: rasters, text extraction, font lists, document information,
#         the image decoders, and signature verification (must run on the
#         target platform)
#   all   both (default)
#
# What the smoke tests found out about the tools, and assert:
# - Built with the "generic" font configuration, every tool prints a
#   "No display font for '<base 14 font>'" configuration error per base 14
#   font when the URW fonts are not installed, and draws no text in a font a
#   file does not embed. The rest of the page is drawn.
# - PPM is the default output of pdftoppm: it has no -ppm option.
# - pdfsig reports "NSS_Init failed" when it finds no NSS database (it looks
#   in ~/.pki/nssdb by default), and still verifies the signatures. Without a
#   database no certificate is trusted: -nocert skips the certificate check.
# - pdfsig exits with 2 for a file without signatures.
# - A JPXDecode stream that is a bare codestream, as PDF allows, is decoded
#   after a "Malformed JP2 file format: first box must be JPEG 2000 signature
#   box" syntax error: Poppler tries the JP2 file format first.
#
# The signature test needs openssl (with its cms command) to sign a file; it
# is skipped without it.
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

# win-x64 has no pdfsig (see scripts/build-poppler.sh).
if [ "$TARGET" = "win-x64" ]; then
  TOOLS="pdftoppm pdftotext pdffonts pdfinfo"
else
  TOOLS="pdftoppm pdftotext pdffonts pdfinfo pdfsig"
fi
for tool in $TOOLS; do
  bin="./$tool-$TARGET$EXE"
  [ -f "$bin" ] || { echo "missing $bin" >&2; exit 1; }
  chmod +x "$bin" 2>/dev/null || true
done
PDFTOPPM="./pdftoppm-$TARGET$EXE"
PDFTOTEXT="./pdftotext-$TARGET$EXE"
PDFFONTS="./pdffonts-$TARGET$EXE"
PDFINFO="./pdfinfo-$TARGET$EXE"
PDFSIG="./pdfsig-$TARGET$EXE"
case " $TOOLS " in
  *" pdfsig "*) HAS_PDFSIG=1 ;;
  *) HAS_PDFSIG="" ;;
esac

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

# A 200x100 page with a red rectangle, a line of Helvetica text, and a 16x16
# RGB image (a red and a blue half), uncompressed (image.bin), DCTDecode
# (image.jpeg) or JPXDecode (image.j2k).
write_sample_pdf() {
  file="$1"; image="${2:-image.bin}"; image_filter="$3"
  printf 'q 1 0 0 rg 10 10 80 80 re f Q\nBT /F1 12 Tf 100 50 Td (Hello PDF) Tj ET\nq 32 0 0 32 160 60 cm /Im1 Do Q\n' > content.bin
  if [ ! -f image.bin ]; then
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
  fi

  pdf_begin "$file"
  pdf_object '<< /Type /Catalog /Pages 2 0 R >>'
  pdf_object '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
  pdf_object '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> >>'
  pdf_stream '' content.bin
  pdf_object '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
  pdf_stream "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 $image_filter" "$image"
  pdf_end
}

# The image of sample.pdf, encoded as a baseline JPEG and as a JPEG 2000
# codestream by MuPDF (mutool clean --color-image-recompress-method).
# jpeg: 529 bytes
write_jpeg() {
  {
    printf '\377\330\377\340\000\020\112\106\111\106\000\001\001\001\000\140\000\140\000\000\377\333\000\103\000\010\006\006\007\006\005\010\007\007\007\011\011\010\012\014'
    printf '\024\015\014\013\013\014\031\022\023\017\024\035\032\037\036\035\032\034\034\040\044\056\047\040\042\054\043\034\034\050\067\051\054\060\061\064\064\064\037\047'
    printf '\071\075\070\062\074\056\063\064\062\377\333\000\103\001\010\011\011\014\013\014\030\015\015\030\062\041\034\041\062\062\062\062\062\062\062\062\062\062\062\062'
    printf '\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\062\377\302'
    printf '\000\021\010\000\020\000\020\003\001\021\000\002\021\001\003\021\001\377\304\000\025\000\001\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\005'
    printf '\377\304\000\027\001\001\001\001\001\000\000\000\000\000\000\000\000\000\000\000\000\000\007\005\006\377\332\000\014\003\001\000\002\020\003\020\000\000\001\213'
    printf '\223\337\210\365\131\250\377\304\000\024\020\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\040\377\332\000\010\001\001\000\001\005\002\037\377'
    printf '\304\000\024\021\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\040\377\332\000\010\001\003\001\001\077\001\037\377\304\000\024\021\001\000\000'
    printf '\000\000\000\000\000\000\000\000\000\000\000\000\000\040\377\332\000\010\001\002\001\001\077\001\037\377\304\000\024\020\001\000\000\000\000\000\000\000\000\000'
    printf '\000\000\000\000\000\000\040\377\332\000\010\001\001\000\006\077\002\037\377\304\000\024\020\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\040'
    printf '\377\332\000\010\001\001\000\001\077\041\037\377\332\000\014\003\001\000\002\000\003\000\000\000\020\157\377\000\377\304\000\024\021\001\000\000\000\000\000\000'
    printf '\000\000\000\000\000\000\000\000\000\040\377\332\000\010\001\003\001\001\077\020\037\377\304\000\024\021\001\000\000\000\000\000\000\000\000\000\000\000\000\000'
    printf '\000\000\040\377\332\000\010\001\002\001\001\077\020\037\377\304\000\024\020\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\040\377\332\000\010'
    printf '\001\001\000\001\077\020\037\377\331'
  } > "$1"
  [ "$(file_size "$1")" -eq 529 ] || fail "$1 was not written correctly"
}
# j2k: 326 bytes
write_j2k() {
  {
    printf '\377\117\377\121\000\057\000\000\000\000\000\020\000\000\000\020\000\000\000\000\000\000\000\000\000\000\000\040\000\000\000\040\000\000\000\000\000\000\000\000'
    printf '\000\003\007\001\001\007\001\001\007\001\001\377\122\000\014\000\000\000\001\001\005\004\004\000\000\377\134\000\043\102\167\040\166\360\166\360\166\300\157\000'
    printf '\157\000\156\340\147\120\147\120\147\150\120\005\120\005\120\107\127\323\127\323\127\142\377\144\000\045\000\001\103\162\145\141\164\145\144\040\142\171\040\117'
    printf '\160\145\156\112\120\105\107\040\166\145\162\163\151\157\156\040\062\056\065\056\064\377\220\000\012\000\000\000\000\000\267\000\001\377\223\307\370\002\007\076'
    printf '\300\007\310\010\000\077\307\370\002\003\131\200\200\200\240\374\300\200\006\373\243\371\002\000\004\243\241\373\001\000\011\154\240\175\240\200\000\173\166\040'
    printf '\241\371\203\200\006\102\173\207\223\275\177\240\374\001\100\000\160\254\067\007\240\372\202\000\017\047\244\215\054\351\272\241\243\360\016\000\014\170\070\247'
    printf '\074\350\213\137\065\036\003\310\146\077\243\360\015\000\017\050\124\247\151\233\367\323\271\103\104\211\177\240\174\343\000\003\204\307\316\016\143\141\000\001'
    printf '\213\101\141\241\366\210\200\000\324\300\237\100\273\201\030\070\343\201\244\113\156\020\165\127\241\366\210\000\003\204\317\065\055\243\001\263\247\376\213\035'
    printf '\357\367\310\116\377\331'
  } > "$1"
  [ "$(file_size "$1")" -eq 326 ] || fail "$1 was not written correctly"
}

# write_signed_pdf <file>: a one-page file with an adbe.pkcs7.detached
# signature of a self-signed certificate, made with openssl.
write_signed_pdf() {
  placeholder=8192
  openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
    -subj "/CN=prebuilt test signer" > openssl.log 2>&1 || { cat openssl.log >&2; fail "openssl req"; }
  printf 'q 1 0 0 rg 10 10 80 80 re f Q\n' > signed-content.bin

  byte_range_placeholder="/ByteRange [0 0000000000 0000000000 0000000000]"
  pdf_begin "$1"
  pdf_object '<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /SigFlags 3 >> >>'
  pdf_object '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
  pdf_object '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << >> /Annots [5 0 R] >>'
  pdf_stream '' signed-content.bin
  pdf_object '<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature1) /Rect [0 0 0 0] /F 132 /P 3 0 R /V 6 0 R >>'
  # The signature dictionary, with room for the signature in /Contents.
  PDF_COUNT=$((PDF_COUNT + 1))
  PDF_OFFSETS="$PDF_OFFSETS $(file_size "$PDF_FILE")"
  printf '%d 0 obj\n<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached ' "$PDF_COUNT" >> "$PDF_FILE"
  byte_range_offset="$(file_size "$PDF_FILE")"
  printf '%s /Contents <' "$byte_range_placeholder" >> "$PDF_FILE"
  contents_start=$(($(file_size "$PDF_FILE") - 1))
  printf '%*s' "$placeholder" '' | tr ' ' 0 >> "$PDF_FILE"
  printf '> /M (D:20260101000000Z) >>\nendobj\n' >> "$PDF_FILE"
  contents_end=$((contents_start + placeholder + 2))
  pdf_end

  # The signed ranges: everything but /Contents <...>.
  total="$(file_size "$PDF_FILE")"
  byte_range="$(printf '/ByteRange [0 %010d %010d %010d]' "$contents_start" "$contents_end" $((total - contents_end)))"
  [ "${#byte_range}" -eq "${#byte_range_placeholder}" ] || fail "the byte range does not fit in its placeholder"
  printf '%s' "$byte_range" | dd of="$PDF_FILE" bs=1 seek="$byte_range_offset" conv=notrunc 2>/dev/null
  { head -c "$contents_start" "$PDF_FILE"; tail -c $((total - contents_end)) "$PDF_FILE"; } > signed-data.bin

  openssl cms -sign -binary -in signed-data.bin -signer cert.pem -inkey key.pem -outform DER -out signature.der \
    -nosmimecap -md sha256 > openssl.log 2>&1 || { cat openssl.log >&2; fail "openssl cms -sign"; }
  signature="$(od -An -v -tx1 signature.der | tr -d ' \n\r')"
  [ "${#signature}" -le "$placeholder" ] || fail "the signature does not fit in /Contents"
  printf '%s' "$signature" | dd of="$PDF_FILE" bs=1 seek=$((contents_start + 1)) conv=notrunc 2>/dev/null
  [ "$(file_size "$PDF_FILE")" -eq "$total" ] || fail "signing changed the size of $PDF_FILE"
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
# background and the two halves of the image are where sample.pdf draws them.
# The text is not checked: Helvetica is not embedded, and is drawn only on a
# machine that has the URW fonts.
assert_sample_raster() {
  assert_ppm_header "$1"
  assert_pixel "$1" 50 50 255 0 0 0
  assert_pixel "$1" 5 5 255 255 255 0
  assert_pixel "$1" 176 12 255 0 0 "$2"
  assert_pixel "$1" 176 36 0 0 255 "$2"
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
  for tool in $TOOLS; do
    # "<tool> version 26.10.0", then the copyright lines, on stderr.
    output="$("./$tool-$TARGET$EXE" -v 2>&1 | tr -d '\r' | head -n 1)"
    if [ -z "$POPPLER_VERSION" ]; then
      echo "  POPPLER_VERSION is not set; skipping the $tool version check: $output"
    else
      [ "$output" = "$tool version $POPPLER_VERSION" ] || fail "$tool does not report version $POPPLER_VERSION: $output"
      ok "$tool reports version $POPPLER_VERSION"
    fi
  done
}

smoke_test() {
  rm -rf poppler-smoke
  mkdir poppler-smoke
  cd poppler-smoke
  PDFTOPPM="../$PDFTOPPM"; PDFTOTEXT="../$PDFTOTEXT"; PDFFONTS="../$PDFFONTS"; PDFINFO="../$PDFINFO"; PDFSIG="../$PDFSIG"
  write_sample_pdf sample.pdf

  msg "pdfinfo"
  run "pdfinfo" "$PDFINFO" sample.pdf
  info="$(tr -d '\r' < tool.log)"
  contains "$info" "Pages:           1" || { echo "$info" >&2; fail "pdfinfo does not report one page"; }
  contains "$info" "Page size:       200 x 100 pts" || { echo "$info" >&2; fail "pdfinfo does not report the page size"; }
  contains "$info" "PDF version:     1.7" || { echo "$info" >&2; fail "pdfinfo does not report PDF 1.7"; }
  contains "$info" "Encrypted:       no" || { echo "$info" >&2; fail "pdfinfo reports encryption"; }
  ok "pdfinfo reports the page count, the page size and the version"

  msg "pdffonts"
  "$PDFFONTS" sample.pdf > fonts.txt 2> fonts.log || { cat fonts.txt fonts.log >&2; fail "pdffonts"; }
  fonts="$(tr -d '\r' < fonts.txt | sed -n '3,$p' | tr -s ' ')"
  [ "$fonts" = "Helvetica Type 1 Standard no no no 5 0" ] || { cat fonts.txt >&2; fail "pdffonts does not list the non-embedded Helvetica: $fonts"; }
  ok "pdffonts lists Helvetica, Type 1, not embedded"

  msg "pdftotext"
  run "pdftotext" "$PDFTOTEXT" sample.pdf sample.txt
  # A form feed ends every page.
  [ "$(tr -d '\r\f' < sample.txt | sed '/^$/d')" = "Hello PDF" ] || fail "the text of sample.pdf is not 'Hello PDF': $(cat sample.txt)"
  run "pdftotext -layout" "$PDFTOTEXT" -layout sample.pdf layout.txt
  contains "$(cat layout.txt)" "Hello PDF" || fail "pdftotext -layout does not extract the text: $(cat layout.txt)"
  ok "pdftotext extracts the text"

  msg "pdftoppm"
  run "pdftoppm" "$PDFTOPPM" -r 72 -singlefile sample.pdf sample
  assert_sample_raster sample.ppm 0
  ok "pdftoppm -r 72 writes the expected PPM raster"

  run "pdftoppm -png" "$PDFTOPPM" -r 72 -png -singlefile sample.pdf sample
  # Signature, then the IHDR chunk: length 13, "IHDR", width 200, height 100.
  header="$(od -An -tu1 -N24 sample.png | tr -s ' \n' ' ' | sed -e 's/^ //' -e 's/ $//')"
  [ "$header" = "137 80 78 71 13 10 26 10 0 0 0 13 73 72 68 82 0 0 0 200 0 0 0 100" ] \
    || fail "sample.png is not a 200x100 PNG file: $header"
  ok "pdftoppm -png writes a 200x100 PNG file"

  run "pdftoppm -r 144" "$PDFTOPPM" -r 144 -png -singlefile sample.pdf sample-144
  header="$(od -An -tu1 -j16 -N8 sample-144.png | tr -s ' \n' ' ' | sed -e 's/^ //' -e 's/ $//')"
  [ "$header" = "0 0 1 144 0 0 0 200" ] || fail "sample-144.png is not 400x200: $header"
  ok "pdftoppm -r 144 doubles the size"

  msg "image decoders"
  write_jpeg image.jpeg
  write_j2k image.j2k
  for codec in "jpeg|DCTDecode" "j2k|JPXDecode"; do
    name="${codec%%|*}"; filter="${codec#*|}"
    write_sample_pdf "$name.pdf" "image.$name" "/Filter /$filter"
    run "pdftoppm $name" "$PDFTOPPM" -r 72 -singlefile "$name.pdf" "$name"
    # The missing fonts and the JP2 attempt aside, nothing is reported.
    if grep -v -e "No display font for" -e "Couldn't find a font for" \
         -e "Malformed JP2 file format: first box must be JPEG 2000 signature box" tool.log | grep -i error; then
      fail "pdftoppm reports an error for the $filter image"
    fi
    assert_sample_raster "$name.ppm" 8
    ok "$filter: the image is decoded"
  done

  if [ -z "$HAS_PDFSIG" ]; then
    cd ..
    ok "all smoke tests passed (no pdfsig for $TARGET)"
    return 0
  fi

  msg "pdfsig"
  set +e
  "$PDFSIG" sample.pdf > tool.log 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ] || { cat tool.log >&2; fail "pdfsig exits with $status for a file without signatures, expected 2"; }
  contains "$(cat tool.log)" "does not contain any signatures" || { cat tool.log >&2; fail "pdfsig does not report the missing signatures"; }
  ok "pdfsig reports a file without signatures (exit code 2)"

  if openssl cms -help > /dev/null 2>&1; then
    write_signed_pdf signed.pdf
    run "pdfsig signed.pdf" "$PDFSIG" -nocert signed.pdf
    signature="$(tr -d '\r' < tool.log)"
    contains "$signature" "Signer Certificate Common Name: prebuilt test signer" || { echo "$signature" >&2; fail "pdfsig does not report the signer"; }
    contains "$signature" "Signing Hash Algorithm: SHA-256" || { echo "$signature" >&2; fail "pdfsig does not report SHA-256"; }
    contains "$signature" "Signature Type: adbe.pkcs7.detached" || { echo "$signature" >&2; fail "pdfsig does not report the signature type"; }
    contains "$signature" "Total document signed" || { echo "$signature" >&2; fail "pdfsig does not report a whole signed document"; }
    contains "$signature" "Signature Validation: Signature is Valid." || { echo "$signature" >&2; fail "pdfsig does not validate the signature"; }
    ok "pdfsig validates an adbe.pkcs7.detached SHA-256 signature"

    # The same file with one signed byte changed: 1 0 0 rg becomes 0 0 1 rg.
    sed 's/^q 1 0 0 rg 10 10 80 80 re f Q$/q 0 0 1 rg 10 10 80 80 re f Q/' signed.pdf > tampered.pdf
    cmp -s signed.pdf tampered.pdf && fail "tampered.pdf was not modified"
    [ "$(file_size tampered.pdf)" -eq "$(file_size signed.pdf)" ] || fail "tampered.pdf does not have the size of signed.pdf"
    "$PDFSIG" -nocert tampered.pdf > tool.log 2>&1 || true
    contains "$(cat tool.log)" "Signature Validation: Digest Mismatch." || { cat tool.log >&2; fail "pdfsig does not detect the modified file"; }
    ok "pdfsig reports a digest mismatch for a modified file"
  else
    echo "  openssl with cms is not available; skipping the signature validation test"
  fi

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    for tool in $TOOLS; do
      assert_linkage "./$tool-$TARGET$EXE"
    done
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
