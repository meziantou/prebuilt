#!/usr/bin/env bash
#
# Verifies the ZXingReader binary built by scripts/build-zxing-cpp.sh.
#
#   bash scripts/verify-zxing-cpp.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertion plus smoke tests (must run on the target platform)
#   all   both (default)
#
# The smoke tests need zint of the same target next to ZXingReader
# (scripts/build-zint.sh): it writes the barcodes of scripts/barcode-samples.sh,
# which ZXingReader must decode, with their format, text and, for QR Code,
# Micro QR and rMQR, the version, error correction level and mask zint was
# asked for, and the module matrix zint dumps.
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
READER="./ZXingReader-$TARGET$EXE"
ZINT="./zint-$TARGET$EXE"
[ -f "$READER" ] || { echo "missing $READER" >&2; exit 1; }
chmod +x "$READER" 2>/dev/null || true

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

# shellcheck source=barcode-samples.sh
. "$SCRIPT_DIR/barcode-samples.sh"

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
# Version
# ---------------------------------------------------------------------------

assert_version() {
  banner="$("$READER" -version 2>&1 | head -n 1 | tr -d '\r')" || fail "ZXingReader -version failed: $banner"
  if [ -z "$ZXING_CPP_VERSION" ]; then
    echo "  ZXING_CPP_VERSION is not set; skipping the version check ($banner)"
    return 0
  fi
  [ "$banner" = "ZXingReader version $ZXING_CPP_VERSION" ] \
    || fail "ZXingReader does not report version $ZXING_CPP_VERSION: $banner"
  ok "ZXingReader reports version $ZXING_CPP_VERSION"
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# zint_matrix <columns> <zint options> <data>: the module matrix of the symbol
# as zint dumps it, one line of 0 and 1 per row. --dump prints 4 modules per
# hexadecimal digit, the first in the high bit.
zint_matrix() {
  columns="$1"; options="$2"; data="$3"
  # shellcheck disable=SC2086
  "$ZINT" $options -d "$data" --dump 2> zint.log | tr -d ' \r' | awk -v columns="$columns" '
    BEGIN {
      split("0000 0001 0010 0011 0100 0101 0110 0111 1000 1001 1010 1011 1100 1101 1110 1111", bits, " ")
      for (i = 0; i < 16; i++) value[substr("0123456789ABCDEF", i + 1, 1)] = bits[i + 1]
    }
    {
      row = ""
      for (i = 1; i <= length($0); i++) row = row value[toupper(substr($0, i, 1))]
      print substr(row, 1, columns)
    }' || { cat zint.log >&2; fail "zint $options --dump failed"; }
}

# reader_matrix <file>: the module matrix ZXingReader detects (-symbol), one
# line of 0 and 1 per row. It prints two rows per line, with half blocks
# (U+2580 upper, U+2584 lower, U+2588 full), and a quiet zone of one module
# around the symbol, which is removed here.
reader_matrix() {
  "$READER" -symbol "$1" | tr -d '\r' | sed -n '/^Symbol:$/,$p' | sed '1d' \
    | sed -e 's/ /0/g' -e "s/$(printf '\342\226\200')/1/g" -e "s/$(printf '\342\226\204')/2/g" -e "s/$(printf '\342\226\210')/3/g" \
    | awk '
      {
        top = ""; bottom = ""
        for (i = 1; i <= length($0); i++) {
          c = substr($0, i, 1)
          top = top ((c == "1" || c == "3") ? "1" : "0")
          bottom = bottom ((c == "2" || c == "3") ? "1" : "0")
        }
        rows[n++] = top; rows[n++] = bottom
      }
      END {
        # Rows 1 to n-2 without the quiet zone; the last line can have a
        # bottom row past the quiet zone.
        last = n - 2
        if (rows[last] ~ /^0*$/ && rows[last - 1] ~ /^0*$/) last--
        for (i = 1; i < last; i++) print substr(rows[i], 2, length(rows[i]) - 2)
      }'
}

# result_field <output> <name>: the value of a "Name:   value" line of the
# output of ZXingReader.
result_field() {
  printf '%s\n' "$1" | sed -n "s/^$2: *//p" | head -n 1
}

smoke_test() {
  [ -f "$ZINT" ] || fail "missing $ZINT, which the smoke tests write the barcodes with"
  chmod +x "$ZINT" 2>/dev/null || true

  workdir="smoke-zxing-cpp-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  READER="../$(basename "$READER")"
  ZINT="../$(basename "$ZINT")"

  msg "decoding the barcodes of zint"
  samples="$(barcode_samples)"
  while IFS='|' read -r name zint_options data reader_options expected symbol _ _; do
    write_barcode "$ZINT" "$name" "$zint_options" "$data"
    # shellcheck disable=SC2086
    output="$("$READER" $reader_options -1 "$name.png" 2>&1 | tr -d '\r')" \
      || { echo "$output" >&2; fail "$name: ZXingReader failed"; }
    found=""
    while IFS= read -r line; do
      [ "$line" = "$name.png $expected" ] && found=1
    done <<EOF
$output
EOF
    [ -n "$found" ] || { echo "$output" >&2; fail "$name: ZXingReader does not read $expected"; }

    if [ -n "$symbol" ]; then
      details="$("$READER" "$name.png" 2>&1 | tr -d '\r')"
      version="${symbol%%/*}"; rest="${symbol#*/}"; level="${rest%%/*}"; mask="${rest#*/}"
      [ "$(result_field "$details" Version)" = "$version" ] || { echo "$details" >&2; fail "$name: not version $version"; }
      [ "$(result_field "$details" ECLevel)" = "$level" ] || { echo "$details" >&2; fail "$name: not level $level"; }
      contains "$(result_field "$details" Extra)" "\"DataMask\":$mask," || { echo "$details" >&2; fail "$name: not mask $mask"; }

      # The module matrix ZXingReader samples is the one zint dumps.
      matrix="$(reader_matrix "$name.png")"
      first="$(printf '%s\n' "$matrix" | head -n 1)"
      [ -n "$first" ] || fail "$name: ZXingReader -symbol printed no symbol"
      dumped="$(zint_matrix "${#first}" "$zint_options" "$data")"
      [ "$matrix" = "$dumped" ] || {
        printf 'ZXingReader:\n%s\nzint --dump:\n%s\n' "$matrix" "$dumped" >&2
        fail "$name: the matrix ZXingReader reads is not the one zint dumps"
      }
      ok "$name: $expected, $version-$level, mask $mask, the ${#first}x$(printf '%s\n' "$matrix" | wc -l | tr -d ' ') matrix of zint --dump"
    else
      ok "$name: $expected"
    fi
  done <<EOF
$samples
EOF

  # The pinned QR Code of scripts/verify-zint.sh, the example of ISO/IEC 18004
  # Annex I.
  write_barcode "$ZINT" iso "-b 58 --vers=1 --secure=2 --mask=2" 01234567
  details="$("$READER" iso.png 2>&1 | tr -d '\r')"
  [ "$(result_field "$details" Text)" = '"01234567"' ] || { echo "$details" >&2; fail "iso.png: not 01234567"; }
  contains "$(result_field "$details" Extra)" '"DataMask":2,' || { echo "$details" >&2; fail "iso.png: not mask 2"; }
  [ "$(result_field "$details" ECLevel)" = M ] || { echo "$details" >&2; fail "iso.png: not level M"; }
  ok "the 1-M mask 2 QR Code of 01234567"

  msg "options"
  # -formats restricts what is looked for.
  output="$("$READER" -formats Code128 -1 qr.png 2>&1 | tr -d '\r')"
  [ "$output" = "qr.png None" ] || { echo "$output" >&2; fail "-formats Code128 found something in a QR Code"; }
  ok "-formats Code128 finds no QR Code"
  # -bytes writes the content only.
  [ "$("$READER" -bytes code128.png)" = "Code128-Test" ] || fail "-bytes does not write the content of code128.png"
  ok "-bytes writes the content"
  # Several files: one result per file.
  output="$("$READER" -1 code93.png codabar.png 2>&1 | tr -d '\r')"
  [ "$output" = "code93.png Code 93 \"CODE93\"
codabar.png Codabar \"A123456B\"" ] || { echo "$output" >&2; fail "two files do not give two results"; }
  ok "one result per file"

  # ZXingReader exits with 0 when it cannot load an image: it prints the
  # error, and no result.
  printf 'not an image' > garbage.png
  output="$("$READER" -1 garbage.png 2>&1 | tr -d '\r')" || true
  contains "$output" "Failed to read image: garbage.png" || { echo "$output" >&2; fail "ZXingReader read garbage.png"; }
  ok "a file that is not an image is reported"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$READER"
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
