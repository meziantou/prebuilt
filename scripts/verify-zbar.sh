#!/usr/bin/env bash
#
# Verifies the zbarimg binary built by scripts/build-zbar.sh.
#
#   bash scripts/verify-zbar.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertion plus smoke tests (must run on the target platform)
#   all   both (default)
#
# The smoke tests need zint of the same target next to zbarimg
# (scripts/build-zint.sh): it writes the barcodes of scripts/barcode-samples.sh,
# which zbarimg must decode, with their type and text, except Micro QR and
# rMQR, which ZBar does not read.
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
ZBARIMG="./zbarimg-$TARGET$EXE"
ZINT="./zint-$TARGET$EXE"
[ -f "$ZBARIMG" ] || { echo "missing $ZBARIMG" >&2; exit 1; }
chmod +x "$ZBARIMG" 2>/dev/null || true

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
      # macOS has no static libSystem; assert only system dylibs are referenced
      # (libiconv is one of them).
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
        # stubs are the UCRT, a Windows component since Windows 10; gdi32 is for
        # the window of the ZBar processor (-d) and GraphicsMagick. Anything
        # else means a dependency leaked in dynamically -- most likely
        # libiconv-2.dll, libpng16.dll or libwinpthread-1.dll.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ucrtbase.dll|api-ms-win-*) ;;
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
  banner="$("$ZBARIMG" --version 2>&1 | head -n 1 | tr -d '\r')" || fail "zbarimg --version failed: $banner"
  if [ -z "$ZBAR_VERSION" ]; then
    echo "  ZBAR_VERSION is not set; skipping the version check ($banner)"
    return 0
  fi
  [ "$banner" = "$ZBAR_VERSION" ] || fail "zbarimg does not report version $ZBAR_VERSION: $banner"
  ok "zbarimg reports version $ZBAR_VERSION"
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# scan <file> [options...]: the output of zbarimg -q, without carriage
# returns, and its exit code in $status.
scan() {
  file="$1"; shift
  status=0
  output="$("$ZBARIMG" -q "$@" "$file" 2>&1 | tr -d '\r')" || status=$?
}

smoke_test() {
  [ -f "$ZINT" ] || fail "missing $ZINT, which the smoke tests write the barcodes with"
  chmod +x "$ZINT" 2>/dev/null || true

  workdir="smoke-zbar-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  ZBARIMG="../$(basename "$ZBARIMG")"
  ZINT="../$(basename "$ZINT")"

  msg "decoding the barcodes of zint"
  samples="$(barcode_samples)"
  while IFS='|' read -r name zint_options data _ _ _ zbar_options expected; do
    write_barcode "$ZINT" "$name" "$zint_options" "$data"
    # shellcheck disable=SC2086
    scan "$name.png" $zbar_options
    if [ "$expected" = "-" ]; then
      # zbarimg exits with 4 when it finds no barcode.
      [ "$status" -eq 4 ] && [ -z "$output" ] || { echo "$output" >&2; fail "$name: zbarimg exited with $status instead of 4"; }
      ok "$name: not read, as ZBar has no decoder for it"
      continue
    fi
    [ "$status" -eq 0 ] || { echo "$output" >&2; fail "$name: zbarimg exited with $status"; }
    # Every expected symbol, and nothing else.
    lines="$(printf '%s\n' "$expected" | tr ';' '\n')"
    [ "$(printf '%s\n' "$output" | sort)" = "$(printf '%s\n' "$lines" | sort)" ] \
      || { echo "$output" >&2; fail "$name: zbarimg does not read $expected"; }
    ok "$name: $(printf '%s' "$expected" | sed 's/;/, /g')"
  done <<EOF
$samples
EOF

  msg "options and formats"
  # Without -Sean5.enable, the add-on is ignored.
  scan ean13-addon5.png
  [ "$output" = "EAN-13:1234567890128" ] || { echo "$output" >&2; fail "the 5-digit add-on is read without -Sean5.enable"; }
  ok "add-ons are ignored unless enabled"

  # The text of a QR Code is converted to UTF-8 with iconv: from UTF-8 (ECI 26)
  # and from ISO 8859-1 (ECI 3) here. zint reads the data from a file (-i), as
  # a command line is not UTF-8 on Windows.
  printf 'Gr\303\274\303\237e \346\227\245\346\234\254' > eci26.txt
  printf 'Gr\303\274\303\237e' > eci3.txt
  for eci in 26 3; do
    data_file="eci$eci.txt"
    rm -f "eci$eci.png"
    "$ZINT" -b 58 --eci="$eci" --scale=4 -i "$data_file" -o "eci$eci.png" > zint.log 2>&1 \
      || { cat zint.log >&2; fail "zint --eci=$eci -i $data_file failed"; }
    scan "eci$eci.png"
    [ "$output" = "QR-Code:$(cat "$data_file")" ] || { echo "$output" >&2; fail "eci$eci.png is not read as UTF-8 text"; }
  done
  ok "QR Codes in UTF-8 (ECI 26) and ISO 8859-1 (ECI 3), read as UTF-8"

  # -Sdisable -S<type>.enable: only these types are looked for.
  scan code93.png -Sdisable -Sqrcode.enable
  [ "$status" -eq 4 ] || { echo "$output" >&2; fail "-Sdisable -Sqrcode.enable still reads Code 93"; }
  ok "-Sdisable -Sqrcode.enable reads no Code 93"

  # Several files, and the XML output.
  status=0
  output="$("$ZBARIMG" -q qr.png codabar.png 2>&1 | tr -d '\r')" || status=$?
  [ "$output" = "QR-Code:Hello, World!
Codabar:A123456B" ] || { echo "$output" >&2; fail "two files do not give two results"; }
  output="$("$ZBARIMG" -q --xml qr.png 2>&1 | tr -d '\r')"
  contains "$output" "<symbol type='QR-Code'" && contains "$output" "<data><![CDATA[Hello, World!]]></data>" \
    || { echo "$output" >&2; fail "--xml does not describe the QR Code"; }
  ok "several files, --xml"

  # GraphicsMagick reads the formats it has without a library; zint writes
  # BMP, GIF and PCX files too.
  for format in bmp gif pcx; do
    rm -f "code128.$format"
    "$ZINT" -b 20 --scale=4 -d Code128-Test -o "code128.$format" > zint.log 2>&1 || { cat zint.log >&2; fail "zint -o code128.$format failed"; }
    scan "code128.$format"
    [ "$output" = "CODE-128:Code128-Test" ] || { echo "$output" >&2; fail "zbarimg does not read code128.$format"; }
  done
  ok "BMP, GIF and PCX files"

  # A file that is not an image, or no file: exit code 1.
  printf 'not an image' > garbage.png
  scan garbage.png
  [ "$status" -eq 1 ] || { echo "$output" >&2; fail "garbage.png: zbarimg exited with $status instead of 1"; }
  scan missing.png
  [ "$status" -eq 1 ] || { echo "$output" >&2; fail "missing.png: zbarimg exited with $status instead of 1"; }
  ok "a file that is not an image, or no file, is an error"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$ZBARIMG"
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
