#!/usr/bin/env bash
#
# Verifies the veraPDF bundle built by scripts/build-verapdf.sh:
# verapdf-<target>.tar.gz, with the launcher (verapdf, or verapdf.exe on
# Windows), lib/verapdf-cli.jar and runtime/ at its root.
#
#   bash scripts/verify-verapdf.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  bundle layout assertions (and the imports of verapdf.exe) only
#   run   version assertion plus smoke tests: the PDF/A and PDF/UA validation
#         of a compliant and of a non-compliant file (must run on the target
#         platform)
#   all   both (default)
#
# What the smoke tests found out about veraPDF, and assert:
# - It exits with 0 when every file is compliant and with 1 otherwise, and
#   prints "PASS <full path> <flavour>" or "FAIL <full path> <flavour>" with
#   --format text.
# - It writes its configuration to a config folder next to the launcher the
#   first time it runs: the bundle must be writable.
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

ARCHIVE="./verapdf-$TARGET.tar.gz"
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

BUNDLE="./verapdf-verify-$TARGET"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
tar -xzf "$ARCHIVE" -C "$BUNDLE"
VERAPDF="$BUNDLE/verapdf$EXE"

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
  printf '%%PDF-%s\n%%\342\343\317\323\n' "${2:-1.7}" > "$PDF_FILE"
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

# pdf_end [trailer entries]
pdf_end() {
  xref="$(file_size "$PDF_FILE")"
  {
    printf 'xref\n0 %d\n0000000000 65535 f \n' $((PDF_COUNT + 1))
    for offset in $PDF_OFFSETS; do
      printf '%010d 00000 n \n' "$offset"
    done
    printf 'trailer\n<< /Size %d /Root 1 0 R %s>>\nstartxref\n%d\n%%%%EOF\n' $((PDF_COUNT + 1)) "${1:+$1 }" "$xref"
  } >> "$PDF_FILE"
}

# A 200x100 page with a line of Helvetica text: not PDF/A (no metadata, no
# /ID, a font that is not embedded), not PDF/UA (not tagged).
write_sample_pdf() {
  printf 'BT /F1 12 Tf 10 50 Td (Hello PDF) Tj ET\n' > content.bin
  pdf_begin "$1"
  pdf_object '<< /Type /Catalog /Pages 2 0 R >>'
  pdf_object '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
  pdf_object '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>'
  pdf_stream '' content.bin
  pdf_object '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
  pdf_end
}

# An empty PDF/A-1b page: the XMP metadata with its PDF/A identification, and
# a file identifier.
write_pdfa_pdf() {
  cat > xmp.bin <<'XMP'
<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
<pdfaid:part>1</pdfaid:part>
<pdfaid:conformance>B</pdfaid:conformance>
</rdf:Description>
</rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
XMP
  pdf_begin "$1" 1.4
  pdf_object '<< /Type /Catalog /Pages 2 0 R /Metadata 4 0 R >>'
  pdf_object '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
  pdf_object '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << >> >>'
  pdf_stream '/Type /Metadata /Subtype /XML' xmp.bin
  pdf_end '/ID [<00112233445566778899AABBCCDDEEFF> <00112233445566778899AABBCCDDEEFF>]'
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

find_objdump() {
  for candidate in x86_64-w64-mingw32-objdump objdump llvm-objdump; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

assert_layout() {
  [ -f "$VERAPDF" ] || fail "$ARCHIVE has no verapdf$EXE at its root"
  [ -f "$BUNDLE/lib/verapdf-cli.jar" ] || fail "$ARCHIVE has no lib/verapdf-cli.jar"
  [ -f "$BUNDLE/runtime/bin/java$EXE" ] || fail "$ARCHIVE has no runtime/bin/java$EXE"
  [ -d "$BUNDLE/runtime/legal/java.base" ] || fail "$ARCHIVE has no runtime/legal/java.base"
  [ -f "$BUNDLE/runtime/release" ] || fail "$ARCHIVE has no runtime/release"
  for module in java.base java.desktop java.sql jdk.charsets jdk.crypto.ec; do
    contains "$(cat "$BUNDLE/runtime/release")" "$module" || fail "the runtime has no $module module"
  done
  if [ -z "$EXE" ]; then
    [ -x "$VERAPDF" ] || fail "verapdf is not executable"
    [ -x "$BUNDLE/runtime/bin/java" ] || fail "runtime/bin/java is not executable"
  fi
  ok "$ARCHIVE has the launcher, the CLI jar and a Java runtime with its legal notices"
}

# The launcher of Windows imports only DLLs of Windows itself.
assert_launcher_linkage() {
  [ "$TARGET" = "win-x64" ] || return 0
  objdump="$(find_objdump)" || fail "no objdump or llvm-objdump to list the imports of $VERAPDF"
  imports="$("$objdump" -p "$VERAPDF" | sed -n 's/^[[:space:]]*DLL Name: //p' | tr 'A-Z' 'a-z' | tr -d '\r' | sort -u)"
  [ -n "$imports" ] || fail "could not list the imports of $VERAPDF"
  for dll in $imports; do
    case "$dll" in
      kernel32.dll|ucrtbase.dll|api-ms-win-*) ;;
      *) fail "$VERAPDF imports a non-system DLL: $dll" ;;
    esac
  done
  ok "$VERAPDF imports only system DLLs ($(echo $imports | tr ' ' ','))"
}

# assert_result <log> <PASS|FAIL> <file> <flavour>: the text report is one
# line, "<PASS|FAIL> <full path of the file> <flavour>".
assert_result() {
  line="$(cat "$1")"
  case "$line" in
    "$2 "*"$3 $4") ;;
    *) echo "$line" >&2; fail "verapdf does not report $2 for $3 ($4)" ;;
  esac
}

# validate <expected exit code> <output file> <arguments...>
validate() {
  expected="$1"; out="$2"; shift 2
  set +e
  "$VERAPDF" "$@" > "$out" 2>&1
  status=$?
  set -e
  tr -d '\r' < "$out" > "$out.tmp" && mv "$out.tmp" "$out"
  [ "$status" -eq "$expected" ] || { cat "$out" >&2; fail "verapdf $* exits with $status, expected $expected"; }
}

assert_version() {
  validate 0 version.log --version
  if [ -z "$VERAPDF_VERSION" ]; then
    echo "  VERAPDF_VERSION is not set; skipping the version check: $(head -n 1 version.log)"
  else
    [ "$(head -n 1 version.log)" = "veraPDF $VERAPDF_VERSION" ] || { cat version.log >&2; fail "verapdf does not report version $VERAPDF_VERSION"; }
    ok "verapdf reports version $VERAPDF_VERSION"
  fi
}

smoke_test() {
  rm -rf verapdf-smoke
  mkdir verapdf-smoke
  cd verapdf-smoke
  VERAPDF="../$VERAPDF"

  msg "profiles"
  validate 0 list.log --list
  for flavour in 1a 1b 2a 2b 2u 3a 3b 3u 4 ua1 ua2; do
    contains "$(cat list.log)" "  $flavour - " || { cat list.log >&2; fail "verapdf --list has no $flavour profile"; }
  done
  ok "the PDF/A-1 to 4 and PDF/UA-1 and 2 profiles are available"

  msg "PDF/A"
  write_pdfa_pdf pdfa.pdf
  validate 0 pdfa.log --flavour 1b --format text pdfa.pdf
  assert_result pdfa.log PASS pdfa.pdf 1b
  ok "an empty page with PDF/A-1b metadata is compliant"

  write_sample_pdf sample.pdf
  validate 1 sample.log --flavour 1b --format text sample.pdf
  assert_result sample.log FAIL sample.pdf 1b
  validate 1 sample.xml --flavour 1b --format xml sample.pdf
  report="$(cat sample.xml)"
  contains "$report" 'isCompliant="false"' || fail "the XML report of sample.pdf is not non-compliant"
  # 6.1.3 (the trailer has no /ID), 6.3.4 (Helvetica is not embedded), 6.7.2 (no metadata)
  for clause in 'clause="6.1.3"' 'clause="6.3.4"' 'clause="6.7.2"'; do
    contains "$report" "$clause" || { echo "$report" >&2; fail "the XML report of sample.pdf does not fail $clause"; }
  done
  ok "a file without metadata, /ID and embedded font fails PDF/A-1b (6.1.3, 6.3.4, 6.7.2)"

  msg "PDF/UA"
  validate 1 ua.log --flavour ua1 --format text sample.pdf
  assert_result ua.log FAIL sample.pdf ua1
  ok "an untagged file fails PDF/UA-1"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

msg "bundle ($TARGET)"
assert_layout

case "$MODE" in
  link|all)
    msg "launcher ($TARGET)"
    assert_launcher_linkage
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
