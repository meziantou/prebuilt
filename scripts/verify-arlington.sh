#!/usr/bin/env bash
#
# Verifies the TestGrammar bundle built by scripts/build-arlington.sh:
# TestGrammar-<target>.tar.gz, with TestGrammar[.exe], tsv/ and LICENSE at its
# root.
#
#   bash scripts/verify-arlington.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  bundle layout and static-linkage assertions only
#   run   version assertion plus smoke tests: the validation of the TSV files,
#         and the check of a well-formed and of a broken PDF file (must run on
#         the target platform)
#   all   both (default)
#
# What the smoke tests found out about TestGrammar, and assert:
# - It has no --version option: the version is in the first line of every
#   report ("BEGIN - TestGrammar v0.81 built <date> ...") and in --help.
# - It exits with 0 whatever it finds: the problems are the "Error:" lines of
#   the report. --no-color leaves the escape sequences out.
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

ARCHIVE="./TestGrammar-$TARGET.tar.gz"
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

BUNDLE="./arlington-verify-$TARGET"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
tar -xzf "$ARCHIVE" -C "$BUNDLE"
TESTGRAMMAR="$BUNDLE/TestGrammar$EXE"

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
        # stubs are the UCRT, a Windows component since Windows 10. The PDFium
        # of TestGrammar also imports gdi32. Anything else means a dependency
        # leaked in dynamically.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|advapi32.dll|shell32.dll|gdi32.dll|ucrtbase.dll|api-ms-win-*) ;;
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

# A 200x100 page with a line of Helvetica text. <font dictionary> replaces
# the font of write_sample_pdf.
write_sample_pdf() {
  printf 'BT /F1 12 Tf 10 50 Td (Hello PDF) Tj ET\n' > content.bin
  pdf_begin "$1"
  pdf_object '<< /Type /Catalog /Pages 2 0 R >>'
  pdf_object '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
  pdf_object '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>'
  pdf_stream '' content.bin
  pdf_object "${2:-<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>}"
  pdf_end
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

assert_layout() {
  [ -f "$TESTGRAMMAR" ] || fail "$ARCHIVE has no TestGrammar$EXE at its root"
  [ -f "$BUNDLE/LICENSE" ] || fail "$ARCHIVE has no LICENSE"
  for version in 1.0 1.1 1.2 1.3 1.4 1.5 1.6 1.7 2.0 latest; do
    [ -f "$BUNDLE/tsv/$version/Catalog.tsv" ] || fail "$ARCHIVE has no tsv/$version/Catalog.tsv"
  done
  entries="$(tar -tzf "$ARCHIVE" | tr -d '\r')"
  for entry in $entries; do
    case "$entry" in
      TestGrammar|TestGrammar.exe|LICENSE|tsv/*) ;;
      *) fail "$ARCHIVE has an unexpected entry: $entry" ;;
    esac
  done
  ok "$ARCHIVE has TestGrammar$EXE, LICENSE and the TSV files of every PDF version"
}

# report <output file> <arguments...>: runs TestGrammar, which must exit with 0.
report() {
  out="$1"; shift
  if ! "$TESTGRAMMAR" --no-color "$@" > "$out" 2>&1; then
    cat "$out" >&2
    fail "TestGrammar $* exits with an error"
  fi
  tr -d '\r' < "$out" > "$out.tmp" && mv "$out.tmp" "$out"
}

assert_version() {
  report help.log --help || true
  if [ -z "$ARLINGTON_VERSION" ]; then
    echo "  ARLINGTON_VERSION is not set; skipping the version check"
  else
    contains "$(cat help.log)" "version v$ARLINGTON_VERSION built" || { cat help.log >&2; fail "TestGrammar --help does not report version v$ARLINGTON_VERSION"; }
    ok "TestGrammar reports version v$ARLINGTON_VERSION"
  fi
}

smoke_test() {
  rm -rf arlington-smoke
  mkdir arlington-smoke
  cd arlington-smoke
  TESTGRAMMAR="../$TESTGRAMMAR"
  TSV="../$BUNDLE/tsv/latest"

  msg "TSV validation"
  report validate.log --tsvdir "$TSV" --validate
  contains "$(cat validate.log)" "BEGIN - Arlington Internal Grammar Validation Report - TestGrammar v" \
    || { cat validate.log >&2; fail "TestGrammar --validate wrote no report"; }
  if grep -E '^(Error|Warning):' validate.log; then
    fail "the TSV files of the bundle do not validate"
  fi
  [ "$(tail -n 1 validate.log)" = "END" ] || { cat validate.log >&2; fail "the validation report does not end with END"; }
  ok "the TSV files of the bundle validate"

  msg "PDF check"
  write_sample_pdf sample.pdf
  report sample.log --tsvdir "$TSV" --pdf sample.pdf
  report=" $(cat sample.log) "
  contains "$report" "TestGrammar v" || { cat sample.log >&2; fail "TestGrammar --pdf wrote no report"; }
  contains "$report" " pdfium" || { cat sample.log >&2; fail "TestGrammar is not built with PDFium"; }
  contains "$report" "Info: Header is version PDF 1.7" || { cat sample.log >&2; fail "TestGrammar does not read the header"; }
  contains "$report" "->Font (as FontMap)->F1 (as FontType1)" || { cat sample.log >&2; fail "TestGrammar does not reach the font"; }
  contains "$report" "DONE - 1 files processed" || { cat sample.log >&2; fail "TestGrammar does not finish"; }
  if grep -E '^Error:' sample.log; then
    fail "TestGrammar reports errors in a well-formed file"
  fi
  ok "a well-formed file has no error"

  # A Type 1 font without its required BaseFont.
  write_sample_pdf broken.pdf '<< /Type /Font /Subtype /Type1 /BaseFonx /Helvetica >>'
  report broken.log --brief --tsvdir "$TSV" --pdf broken.pdf
  contains "$(cat broken.log)" "Error: non-inheritable required key does not exist: BaseFont (FontType1) in PDF 1.7" \
    || { cat broken.log >&2; fail "TestGrammar does not report the missing BaseFont"; }
  contains "$(cat broken.log)" "Info: unknown key 'BaseFonx' is not defined in Arlington for FontType1 in PDF 1.7" \
    || { cat broken.log >&2; fail "TestGrammar does not report the unknown key"; }
  ok "a font without BaseFont is reported"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

msg "bundle ($TARGET)"
assert_layout

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$TESTGRAMMAR"
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
