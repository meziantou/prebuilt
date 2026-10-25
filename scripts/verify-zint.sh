#!/usr/bin/env bash
#
# Verifies the zint binary built by scripts/build-zint.sh.
#
#   bash scripts/verify-zint.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertion plus smoke tests (must run on the target platform)
#   all   both (default)
#
# The smoke tests check that zint pins what it is asked to pin: the module
# matrix of a QR Code of a given version, mask and error correction level
# (--dump), the size of Micro QR and rMQR versions, and that every barcode of
# scripts/barcode-samples.sh is written to a PNG file. scripts/verify-zxing-cpp.sh
# and scripts/verify-zbar.sh decode these files.
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
ZINT="./zint-$TARGET$EXE"
[ -f "$ZINT" ] || { echo "missing $ZINT" >&2; exit 1; }
chmod +x "$ZINT" 2>/dev/null || true

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
        # libunwind.dll, libwinpthread-1.dll or libpng16.dll.
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
  banner="$("$ZINT" --version 2>&1 | head -n 1 | tr -d '\r')" || fail "zint --version failed: $banner"
  if [ -z "$ZINT_VERSION" ]; then
    echo "  ZINT_VERSION is not set; skipping the version check ($banner)"
    return 0
  fi
  case "$banner" in
    "Zint version $ZINT_VERSION "*|"Zint version $ZINT_VERSION") ok "zint reports version $ZINT_VERSION" ;;
    *) fail "zint does not report version $ZINT_VERSION: $banner" ;;
  esac
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# dump <options...>: the --dump output of zint, without carriage returns.
dump() {
  "$ZINT" "$@" --dump 2> zint.log | tr -d '\r' || { cat zint.log >&2; fail "zint $* --dump failed"; }
}

# expect_size <label> <rows> <columns> <options...>: --dump prints one line
# per row of modules, in hexadecimal, 4 modules per digit, the first module in
# the high bit, in groups of 2 digits; the last group has the digits the row
# needs only. The size of the symbol is the number of lines and the length of
# the lines.
expect_size() {
  label="$1"; rows="$2"; columns="$3"; shift 3
  digits=$(((columns + 3) / 4))
  matrix="$(dump "$@")"
  [ "$(printf '%s\n' "$matrix" | wc -l | tr -d ' ')" -eq "$rows" ] \
    || { printf '%s\n' "$matrix" >&2; fail "$label does not have $rows rows"; }
  first="$(printf '%s\n' "$matrix" | head -n 1 | tr -d ' ')"
  [ "${#first}" -eq "$digits" ] || { printf '%s\n' "$matrix" >&2; fail "$label rows do not have $digits hexadecimal digits: $first"; }
  ok "$label: $columns x $rows modules"
}

smoke_test() {
  workdir="smoke-zint-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  ZINT="../$(basename "$ZINT")"

  # The input and the parameters of the example of ISO/IEC 18004 Annex I:
  # "01234567", version 1, level M, mask 2. The matrix is the one zint
  # $ZINT_VERSION writes; scripts/verify-zxing-cpp.sh checks that ZXingReader
  # reads it back with the same version, level and mask.
  msg "QR Code module matrix (--dump)"
  expected='FE 5B F8
82 7A 08
BA 82 E8
BA C2 E8
BA BA E8
82 8A 08
FE AB F8
00 98 00
BE 4B E0
15 A9 60
23 54 F8
08 41 E0
1F 94 80
00 BE 60
FE 6B 00
82 BE 28
BA 89 60
BA C9 00
BA B4 A0
82 01 B0
FE F4 A0'
  actual="$(dump -b 58 --vers=1 --secure=2 --mask=2 -d 01234567)"
  [ "$actual" = "$expected" ] || { printf '%s\n' "$actual" >&2; fail "the 1-M mask 2 QR Code of 01234567 is not the expected matrix"; }
  ok "01234567 as a 1-M QR Code with mask 2 is the expected 21x21 matrix"

  # --mask, --secure and --vers each change the symbol.
  [ "$(dump -b 58 --vers=1 --secure=2 --mask=5 -d 01234567)" != "$expected" ] || fail "--mask=5 gives the same matrix as --mask=2"
  ok "--mask selects the mask"
  [ "$(dump -b 58 --vers=1 --secure=4 --mask=2 -d 01234567)" != "$expected" ] || fail "--secure=4 gives the same matrix as --secure=2"
  ok "--secure selects the error correction level"
  expect_size "QR Code version 1" 21 21 -b 58 --vers=1 -d 01234567
  expect_size "QR Code version 2" 25 25 -b 58 --vers=2 -d 01234567
  expect_size "QR Code version 10" 57 57 -b 58 --vers=10 -d 01234567
  expect_size "Micro QR Code M2" 13 13 -b 97 --vers=2 -d 12345
  expect_size "Micro QR Code M4" 17 17 -b 97 --vers=4 -d 12345
  expect_size "rMQR R7x43" 7 43 -b 145 --vers=1 -d ABC123
  expect_size "rMQR R11x59" 11 59 -b 145 --vers=13 -d ABC123

  # A version too small for the data is an error, not a larger symbol.
  if "$ZINT" -b 58 --vers=1 --secure=4 -d "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" --dump > zint.log 2>&1; then
    cat zint.log >&2; fail "zint wrote a 1-H QR Code of 36 characters"
  fi
  contains "$(cat zint.log)" "Input too long for Version 1-H" || { cat zint.log >&2; fail "zint does not say why it rejects the data"; }
  ok "a version too small for the data is rejected"

  # Code 39: --vers=1 adds the modulo 43 check character, a 13-module character.
  plain="$(dump -b 8 -d CODE39 | tr -d ' ')"
  checked="$(dump -b 8 --vers=1 -d CODE39 | tr -d ' ')"
  [ "$plain" != "$checked" ] && [ "${#checked}" -gt "${#plain}" ] || fail "Code 39 --vers=1 does not add a check character"
  ok "Code 39 --vers=1 adds the check character"

  # Add-ons make the EAN-13 symbol wider.
  ean13="$(dump -b 15 -d 123456789012 | tr -d ' ')"
  addon="$(dump -b 15 -d 123456789012+12345 | tr -d ' ')"
  [ "${#addon}" -gt "${#ean13}" ] || fail "the EAN-13 symbol with a 5-digit add-on is not wider"
  ok "EAN-13 with a 5-digit add-on"

  msg "PNG files"
  barcode_samples | while IFS='|' read -r name zint_options data _ _ _ _; do
    write_barcode "$ZINT" "$name" "$zint_options" "$data"
    ok "$name.png ($zint_options)"
  done

  # zint writes out.png when no -o is given; the file type follows the extension.
  rm -f out.png
  "$ZINT" -b 20 -d test > zint.log 2>&1 || { cat zint.log >&2; fail "zint without -o failed"; }
  [ -s out.png ] || fail "zint without -o did not write out.png"
  "$ZINT" -b 20 -d test -o code.svg > zint.log 2>&1 || { cat zint.log >&2; fail "zint -o code.svg failed"; }
  contains "$(cat code.svg)" "<svg" || fail "code.svg is not an SVG file"
  ok "out.png by default, SVG from the extension"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$ZINT"
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
