#!/usr/bin/env bash
#
# Verifies the woff2_compress/woff2_decompress/woff2_info set built by
# scripts/build-woff2.sh.
#
#   bash scripts/verify-woff2.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   usage assertions plus a real compress+decompress round-trip (must run
#         on the target platform)
#   all   both (default)
#
# The woff2 tools have no --version and print no version anywhere, so there is
# no version assertion: the sources are pinned by commit in build-woff2.sh.
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

WOFF2_COMPRESS="./woff2_compress-$TARGET$EXE"
WOFF2_DECOMPRESS="./woff2_decompress-$TARGET$EXE"
WOFF2_INFO="./woff2_info-$TARGET$EXE"
for bin in "$WOFF2_COMPRESS" "$WOFF2_DECOMPRESS" "$WOFF2_INFO"; do
  [ -f "$bin" ] || { echo "missing $bin" >&2; exit 1; }
  chmod +x "$bin" 2>/dev/null || true
done

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
# Usage
# ---------------------------------------------------------------------------

# Each tool takes exactly one argument, the input file.
assert_usage() {
  tool="$1"; bin="$2"
  status=0
  output="$("$bin" 2>&1)" || status=$?
  [ "$status" -eq 1 ] || fail "$tool without an argument exited with $status instead of 1: $output"
  contains "$output" "One argument, the input filename, must be provided." \
    || fail "$tool without an argument does not print its usage: $output"
  ok "$tool asks for its input file"
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# run <label> <output file> <command...>: the command succeeds and writes the file.
run() {
  label="$1"; out="$2"; shift 2
  rm -f "$out"
  "$@" > tool.log 2>&1 || { cat tool.log >&2; fail "$label: $(basename "$1") failed"; }
  [ -s "$out" ] || { cat tool.log >&2; fail "$label: $(basename "$1") produced no file"; }
}

# rejects <label> <command...>: the command fails.
rejects() {
  label="$1"; shift
  if "$@" > tool.log 2>&1; then
    cat tool.log >&2
    fail "$label: $(basename "$1") succeeded"
  fi
}

# first_bytes <file> <count>: the first bytes of the file, in hexadecimal.
first_bytes() {
  od -An -tx1 -N "$2" "$1" | tr -d ' \n\r'
}

# expect_info <file> <text>...: every text is in the output of woff2_info.
expect_info() {
  file="$1"; shift
  info="$("$WOFF2_INFO" "$file" 2>&1 | tr -d '\r')" || { echo "$info" >&2; fail "woff2_info $file failed"; }
  for text in "$@"; do
    contains "$info" "$text" || { echo "$info" >&2; fail "$file: woff2_info does not report '$text'"; }
  done
  ok "$file: $*"
}

smoke_test() {
  workdir="smoke-woff2-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  WOFF2_COMPRESS="../$(basename "$WOFF2_COMPRESS")"
  WOFF2_DECOMPRESS="../$(basename "$WOFF2_DECOMPRESS")"
  WOFF2_INFO="../$(basename "$WOFF2_INFO")"

  # A TrueType font of 12 tables and 4 glyphs: .notdef, A, B and the ligature
  # of A and B, with a `liga` and a `kern` feature. scripts/verify-harfbuzz.sh
  # shapes the same font.
  base64 -d > source.ttf <<'EOF'
AAEAAAAMAIAAAwBAR1BPUytvJGQAAALcAAAAVkdTVUIgliVpAAADNAAAAFZPUy8yRSFEzgAAAUgA
AABgY21hcAAMAJUAAAG4AAAANGdseWY0cgr/AAAB+AAAAE5oZWFkMajtKgAAAMwAAAA2aGhlYQfS
BB8AAAEEAAAAJGhtdHgLuACWAAABqAAAABBsb2NhADQAGgAAAewAAAAKbWF4cAAGAAYAAAEoAAAA
IG5hbWUCv9wRAAACSAAAAHJwb3N0AAMAAAAAArwAAAAgAAEAAAABAAD7Sh6sXw889QADA+gAAAAA
5vFUxwAAAADm8VTHADIAAAR+ArwAAAADAAIAAAAAAAAAAQAAAyD/OAAABLAAMgAyBH4AAQAAAAAA
AAAAAAAAAAAAAAQAAQAAAAQABAABAAAAAAACAAAAAAAAAAAAAAAAAAAAAAADAu4BkAAFAAQAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAA/Pz8/AAAAQQBCAyD/
OAAAAyAAyAAAAAAAAAAAAAAAAAAAACAAAgH0AAACWAAyArwAMgSwADIAAAACAAAAAwAAABQAAwAB
AAAAFAAEACAAAAAEAAQAAQAAAEL//wAAAEH////AAAEAAAAAAAAAAAANABoAJwAAAAEAMgAAAiYC
vAADAAAzESERMgH0Arz9RAAAAQAyAAACigK8AAMAADMRIREyAlgCvP1EAAABADIAAAR+ArwAAwAA
MxEhETIETAK8/UQAAAAAAAAEADYAAQAAAAAAAQANAAAAAQAAAAAAAgAHAA0AAwABBAkAAQAaABQA
AwABBAkAAgAOAC5QcmVidWlsdCBUZXN0UmVndWxhcgBQAHIAZQBiAHUAaQBsAHQAIABUAGUAcwB0
AFIAZQBnAHUAbABhAHIAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAKACQA
MgACREZMVAAObGF0bgAOAAQAAAAA//8AAQAAAAFrZXJuAAgAAAABAAAAAQAEAAIAAAABAAgAAQAM
AAQAAAABABIAAQABAAEAAQAC/84AAAABAAAACgAkADIAAkRGTFQADmxhdG4ADgAEAAAAAP//AAEA
AAABbGlnYQAIAAAAAQAAAAEABAAEAAAAAQAIAAEAEgABAAgAAQAEAAMAAgACAAEAAQABAAA=
EOF
  [ "$(($(wc -c < source.ttf)))" -eq 908 ] || fail "source.ttf was not written correctly"
  ok "wrote the TrueType input"

  # woff2_compress writes <name>.woff2 next to its input.
  msg "woff2_compress"
  cp source.ttf font.ttf
  run "compress" font.woff2 "$WOFF2_COMPRESS" font.ttf
  [ "$(head -c 4 font.woff2)" = "wOF2" ] || fail "font.woff2 is not a WOFF2 file"
  [ "$(($(wc -c < font.woff2)))" -lt 908 ] || fail "font.woff2 is not smaller than its input"
  ok "font.ttf -> font.woff2 ($(($(wc -c < font.woff2))) bytes)"

  msg "woff2_info"
  expect_info font.woff2 "signature           0x774f4632" "flavor              0x00010000" \
    "numTables           12" "totalSfntSize       912" \
    " GPOS " " GSUB " " OS/2 " " cmap " " glyf " " loca " " head " " hhea " " hmtx " " maxp " " name " " post "
  rejects "a TrueType file" "$WOFF2_INFO" source.ttf
  contains "$(cat tool.log)" "Invalid signature: 00010000" || { cat tool.log >&2; fail "woff2_info accepted a TrueType file"; }
  ok "woff2_info rejects a file that is not WOFF2"

  # woff2_decompress writes <name>.ttf next to its input. The glyf and loca
  # tables are rebuilt and the tables are padded, so the result is a different
  # file with the same tables: compressing it again gives the same WOFF2.
  msg "woff2_decompress"
  mkdir roundtrip
  cp font.woff2 roundtrip/font.woff2
  run "decompress" roundtrip/font.ttf "$WOFF2_DECOMPRESS" roundtrip/font.woff2
  [ "$(first_bytes roundtrip/font.ttf 6)" = "00010000000c" ] \
    || fail "roundtrip/font.ttf is not a TrueType file of 12 tables: $(first_bytes roundtrip/font.ttf 6)"
  [ "$(($(wc -c < roundtrip/font.ttf)))" -eq 912 ] || fail "roundtrip/font.ttf is not the 912 bytes font.woff2 declares"
  ok "font.woff2 -> font.ttf (TrueType, 12 tables, 912 bytes)"
  rm roundtrip/font.woff2
  run "compress again" roundtrip/font.woff2 "$WOFF2_COMPRESS" roundtrip/font.ttf
  cmp -s font.woff2 roundtrip/font.woff2 || fail "compressing the decompressed font gives a different WOFF2 file"
  ok "compress -> decompress -> compress is stable"

  rejects "a TrueType file" "$WOFF2_DECOMPRESS" source.ttf
  ok "woff2_decompress rejects a file that is not WOFF2"
  printf 'not a font' > garbage.ttf
  rejects "a file that is not a font" "$WOFF2_COMPRESS" garbage.ttf
  ok "woff2_compress rejects a file that is not a font"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$WOFF2_COMPRESS"
    assert_linkage "$WOFF2_DECOMPRESS"
    assert_linkage "$WOFF2_INFO"
    ;;
esac

case "$MODE" in
  run|all)
    msg "usage"
    assert_usage woff2_compress "$WOFF2_COMPRESS"
    assert_usage woff2_decompress "$WOFF2_DECOMPRESS"
    assert_usage woff2_info "$WOFF2_INFO"
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
