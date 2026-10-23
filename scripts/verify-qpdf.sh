#!/usr/bin/env bash
#
# Verifies the qpdf built by scripts/build-qpdf.sh.
#
#   bash scripts/verify-qpdf.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertion plus smoke tests of what qpdf is published for:
#         structure checks, JSON dumps, every encryption variant, QDF output,
#         and the JPEG code (must run on the target platform)
#   all   both (default)
#
# What the smoke tests found out about qpdf, and assert:
# - Writing a file with RC4 encryption (40 or 128 bits) needs
#   --allow-weak-crypto; reading one does not.
# - --optimize-images turns an image into a DCTDecode stream only when the
#   result is smaller; the --oi-min-* options lower the size thresholds.
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

QPDF="./qpdf-$TARGET$EXE"
[ -f "$QPDF" ] || { echo "missing $QPDF" >&2; exit 1; }
chmod +x "$QPDF" 2>/dev/null || true

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
        # stubs are the UCRT, a Windows component since Windows 10. advapi32
        # is the secure random number generator of the native crypto provider.
        # Anything else means a dependency leaked in dynamically.
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

# qpdf exits with 0 when everything is fine, 2 on errors, 3 on warnings.
assert_check() {
  file="$1"; shift
  run "qpdf --check $file" "$QPDF" --check "$@" "$file"
  contains "$(cat tool.log)" "No syntax or stream encoding errors found" \
    || { cat tool.log >&2; fail "qpdf --check reports problems in $file"; }
}

assert_version() {
  output="$("$QPDF" --version 2>&1 | tr -d '\r')"
  if [ -z "$QPDF_VERSION" ]; then
    echo "  QPDF_VERSION is not set; skipping the version check: $output"
  else
    # The first line is "<program name> version 12.4.2".
    contains "$output" " version $QPDF_VERSION
" || fail "qpdf does not report version $QPDF_VERSION: $output"
    ok "qpdf reports version $QPDF_VERSION"
  fi

  crypto="$("$QPDF" --show-crypto 2>&1 | tr -d '\r')"
  [ "$crypto" = "native" ] || fail "qpdf has other crypto providers than native: $crypto"
  ok "native is the only crypto provider"
}

smoke_test() {
  rm -rf qpdf-smoke
  mkdir qpdf-smoke
  cd qpdf-smoke
  QPDF="../$QPDF"

  msg "structure"
  write_sample_pdf sample.pdf
  assert_check sample.pdf
  ok "--check accepts a well-formed file"

  # A broken cross-reference table (a wrong offset for object 1): qpdf
  # recovers, warns, and exits with 3.
  awk 'done != 1 && / 00000 n $/ { print "0000000099 00000 n "; done = 1; next } { print }' sample.pdf > broken.pdf
  cmp -s sample.pdf broken.pdf && fail "broken.pdf was not modified"
  set +e
  "$QPDF" --check broken.pdf > tool.log 2>&1
  status=$?
  set -e
  [ "$status" -eq 3 ] || { cat tool.log >&2; fail "qpdf --check exits with $status on a broken xref table, expected 3"; }
  contains "$(cat tool.log)" "WARNING" || { cat tool.log >&2; fail "qpdf --check does not warn about the broken xref table"; }
  ok "--check warns about a broken cross-reference table (exit code 3)"

  msg "JSON"
  run "qpdf --json" "$QPDF" --json sample.pdf
  json="$(cat tool.log)"
  contains "$json" '"version": 2' || fail "qpdf --json does not write version 2 JSON"
  contains "$json" '"pages": [' || fail "qpdf --json has no pages"
  contains "$json" '"/BaseFont": "/Helvetica"' || fail "qpdf --json does not dump the font dictionary"
  ok "--json dumps the objects"

  # Writing a file compresses its streams and adds an /ID: the first rebuild
  # differs from the original, and every following one is the same.
  run "qpdf --json-output" "$QPDF" --json-output sample.pdf sample.json
  run "qpdf --json-input" "$QPDF" --static-id --json-input sample.json rebuilt.pdf
  assert_check rebuilt.pdf
  run "qpdf --show-object of the rebuilt file" "$QPDF" --show-object=4 --filtered-stream-data rebuilt.pdf
  cmp -s tool.log content.bin || fail "the content stream of the file rebuilt from JSON differs"
  run "qpdf --json of the rebuilt file" "$QPDF" --json-output rebuilt.pdf rebuilt.json
  run "qpdf --json-input of the rebuilt file" "$QPDF" --static-id --json-input rebuilt.json rebuilt2.pdf
  run "qpdf --json of the second rebuilt file" "$QPDF" --json-output rebuilt2.pdf rebuilt2.json
  cmp -s rebuilt.json rebuilt2.json || fail "the JSON of a file rebuilt twice from JSON differs"
  ok "--json-output and --json-input round-trip"

  msg "encryption"
  # <name>|<global options>|<encryption options>|<R value>|<stream method>
  # qpdf reports a stream method from revision 4 on; RC4 is the only method of
  # revisions 2 and 3.
  for variant in \
    "rc4-40|--allow-weak-crypto|--bits=40|2|" \
    "rc4-128|--allow-weak-crypto|--bits=128 --use-aes=n|3|" \
    "aes-128||--bits=128 --use-aes=y|4|AESv2" \
    "aes-256||--bits=256|6|AESv3"; do
    name="${variant%%|*}"; rest="${variant#*|}"
    global_options="${rest%%|*}"; rest="${rest#*|}"
    encryption_options="${rest%%|*}"; rest="${rest#*|}"
    revision="${rest%%|*}"; method="${rest#*|}"
    # shellcheck disable=SC2086
    run "qpdf --encrypt $name" "$QPDF" $global_options --encrypt --user-password=user --owner-password=owner \
      $encryption_options -- sample.pdf "$name.pdf"
    contains "$(cat "$name.pdf")" "/Encrypt" || fail "$name.pdf has no /Encrypt entry"

    run "qpdf --show-encryption $name" "$QPDF" --show-encryption --password=user "$name.pdf"
    encryption="$(tr -d '\r' < tool.log)"
    contains "$encryption" "R = $revision" || { echo "$encryption" >&2; fail "$name.pdf is not encrypted with revision $revision"; }
    if [ -n "$method" ]; then
      contains "$encryption" "stream encryption method: $method" || { echo "$encryption" >&2; fail "$name.pdf streams are not encrypted with $method"; }
    else
      contains "$encryption" "AES" && { echo "$encryption" >&2; fail "$name.pdf is encrypted with AES"; }
      method="RC4"
    fi

    assert_check "$name.pdf" --password=user
    assert_check "$name.pdf" --password=owner

    set +e
    "$QPDF" --check --password=wrong "$name.pdf" > tool.log 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || { cat tool.log >&2; fail "qpdf opens $name.pdf with a wrong password (exit code $status)"; }
    contains "$(cat tool.log)" "invalid password" || { cat tool.log >&2; fail "qpdf does not report the wrong password of $name.pdf"; }

    run "qpdf --decrypt $name" "$QPDF" --decrypt --password=user "$name.pdf" "$name-decrypted.pdf"
    assert_check "$name-decrypted.pdf"
    run "qpdf --show-object $name" "$QPDF" --show-object=4 --filtered-stream-data "$name-decrypted.pdf"
    cmp -s tool.log content.bin || fail "the decrypted content stream of $name.pdf is not the original"
    run "qpdf --show-object $name" "$QPDF" --password=user --show-object=6 --filtered-stream-data "$name.pdf"
    cmp -s tool.log image.bin || fail "the image of $name.pdf does not decrypt to the original"
    ok "$name: R = $revision, $method, user and owner passwords, wrong password, decrypt"
  done

  set +e
  "$QPDF" --encrypt --user-password=user --owner-password=owner --bits=40 -- sample.pdf weak.pdf > tool.log 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "qpdf writes RC4 encryption without --allow-weak-crypto"
  ok "RC4 encryption needs --allow-weak-crypto"

  msg "QDF"
  run "qpdf --qdf" "$QPDF" --qdf --object-streams=disable sample.pdf sample.qdf
  head -c 9 sample.qdf | grep '^%PDF-1.7$' > /dev/null || fail "sample.qdf does not start with the PDF header"
  contains "$(cat sample.qdf)" "%QDF-1.0" || fail "sample.qdf is not a QDF file"
  contains "$(cat sample.qdf)" "%% Original object ID: 4 0" || fail "sample.qdf has no original object IDs"
  assert_check sample.qdf
  ok "--qdf writes a QDF file"

  msg "JPEG"
  # libjpeg is linked statically: --optimize-images encodes the image with it,
  # and --decode-level=all decodes it back.
  run "qpdf --optimize-images" "$QPDF" --optimize-images --oi-min-width=0 --oi-min-height=0 --oi-min-area=0 \
    --object-streams=disable sample.pdf optimized.pdf
  run "qpdf --json of optimized.pdf" "$QPDF" --json optimized.pdf
  contains "$(cat tool.log)" '"/Filter": "/DCTDecode"' || { cat tool.log >&2; fail "--optimize-images did not write a DCTDecode image"; }
  assert_check optimized.pdf
  run "qpdf --decode-level=all" "$QPDF" --decode-level=all --object-streams=disable optimized.pdf decoded.pdf
  contains "$(cat decoded.pdf)" "/DCTDecode" && fail "--decode-level=all did not decode the DCTDecode image"
  # qpdf numbers the objects of the files it writes in the order it reaches
  # them, which is the order of sample.pdf: the image is object 6.
  run "qpdf --show-object" "$QPDF" --show-object=6 optimized.pdf
  contains "$(cat tool.log)" "/DCTDecode" || { cat tool.log >&2; fail "object 6 of optimized.pdf is not the DCTDecode image"; }
  run "qpdf --show-object --filtered-stream-data" "$QPDF" --decode-level=all --show-object=6 --filtered-stream-data optimized.pdf
  [ "$(file_size tool.log)" -eq 768 ] || fail "the decoded image has $(file_size tool.log) bytes, expected 768"
  # The first pixel is red, the last one blue, within the JPEG loss.
  first="$(od -An -tu1 -N3 tool.log | tr -s ' ' | sed 's/^ //')"
  last="$(od -An -tu1 -j765 -N3 tool.log | tr -s ' ' | sed 's/^ //')"
  set -- $first
  [ "$1" -gt 200 ] && [ "$2" -lt 60 ] && [ "$3" -lt 60 ] || fail "the first decoded pixel is not red: $first"
  set -- $last
  [ "$1" -lt 60 ] && [ "$2" -lt 60 ] && [ "$3" -gt 200 ] || fail "the last decoded pixel is not blue: $last"
  ok "an image is encoded to and decoded from DCTDecode"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$QPDF"
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
