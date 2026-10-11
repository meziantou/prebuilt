#!/usr/bin/env bash
#
# Verifies the hb-shape/hb-info/hb-subset/hb-vector/hb-raster set built by
# scripts/build-harfbuzz.sh.
#
#   bash scripts/verify-harfbuzz.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   --version, shaper and font-function assertions plus real smoke tests
#         of what the tools are published for (must run on the target platform)
#   all   both (default)
#
# The smoke tests need woff2_compress of the same target next to the HarfBuzz
# tools (scripts/build-woff2.sh): it writes the WOFF2 file FreeType has to open.
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

HB_SHAPE="./hb-shape-$TARGET$EXE"
HB_INFO="./hb-info-$TARGET$EXE"
HB_SUBSET="./hb-subset-$TARGET$EXE"
HB_VECTOR="./hb-vector-$TARGET$EXE"
HB_RASTER="./hb-raster-$TARGET$EXE"
WOFF2_COMPRESS="./woff2_compress-$TARGET$EXE"
for bin in "$HB_SHAPE" "$HB_INFO" "$HB_SUBSET" "$HB_VECTOR" "$HB_RASTER"; do
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

# has_line <text> <line>: one of the lines of the text is exactly <line>.
has_line() {
  case "
$1
" in
    *"
$2
"*) return 0 ;;
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
      # GLib uses the libiconv and the Foundation framework of the system.
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
        # stubs are the UCRT, a Windows component since Windows 10. ole32 and
        # ws2_32 are what GLib uses. Anything else means a dependency leaked in
        # dynamically -- most likely libc++.dll, libunwind.dll,
        # libwinpthread-1.dll or a GLib DLL.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|advapi32.dll|shell32.dll|ucrtbase.dll|api-ms-win-*) ;;
          ole32.dll|ws2_32.dll) ;;
          *) bad="$bad $dll" ;;
        esac
      done
      [ -z "$bad" ] || fail "$bin imports non-system DLLs:$bad"
      ok "$bin imports only system DLLs ($(echo $imports | tr ' ' ','))"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Version, shapers, font functions and command-line options
# ---------------------------------------------------------------------------

# Every tool prints its program name, which is the name of the file, then the
# version of HarfBuzz, for instance:
#   hb-shape-linux-x64 (HarfBuzz) 14.6.0
assert_version() {
  tool="$1"; bin="$2"
  banner="$("$bin" --version 2>&1)" || fail "$tool --version failed: $banner"
  banner="${banner%%$'\n'*}"
  banner="${banner%$'\r'}"
  echo "  $tool: $banner"

  if [ -z "$HARFBUZZ_VERSION" ]; then
    echo "  HARFBUZZ_VERSION is not set; skipping the $tool version check"
  else
    case "$banner" in
      *" (HarfBuzz) $HARFBUZZ_VERSION") ok "$tool reports version $HARFBUZZ_VERSION" ;;
      *) fail "$tool does not report version $HARFBUZZ_VERSION: $banner" ;;
    esac
  fi
}

# assert_list <tool> <binary> <option> <wanted> <unwanted>: the option lists one
# name per line, with every wanted name and none of the unwanted ones.
assert_list() {
  tool="$1"; bin="$2"; option="$3"; wanted="$4"; unwanted="$5"
  list="$("$bin" "$option" 2>&1 | tr -d '\r')" || fail "$tool $option failed: $list"
  for name in $wanted; do
    has_line "$list" "$name" || fail "$tool $option does not list $name: $(echo $list)"
  done
  for name in $unwanted; do
    if has_line "$list" "$name"; then
      fail "$tool $option lists $name, which no target is built with: $(echo $list)"
    fi
  done
  ok "$tool $option: $(echo $list)"
}

# assert_options <tool> <binary> <option>...: the full help lists every option.
assert_options() {
  tool="$1"; bin="$2"; shift 2
  help="$("$bin" --help-all 2>&1)" || fail "$tool --help-all failed"
  for option in "$@"; do
    contains "$help" "$option" || fail "$tool --help-all does not list $option"
  done
  ok "$tool --help-all lists $*"
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

# expect_shape <label> <expected JSON> <hb-shape arguments...>: with the ot
# shaper, JSON output and glyph indices.
expect_shape() {
  label="$1"; expected="$2"; shift 2
  actual="$("$HB_SHAPE" --shapers=ot --output-format=json --no-glyph-names "$@" 2>&1 | tr -d '\r')" \
    || { echo "$actual" >&2; fail "$label: hb-shape failed"; }
  [ "$actual" = "$expected" ] || fail "$label: hb-shape printed $actual instead of $expected"
  ok "$label"
}

# expect_output <label> <text>...: every text is in the output of the command
# in $COMMAND.
expect_output() {
  label="$1"; shift
  output="$($COMMAND 2>&1 | tr -d '\r')" || { echo "$output" >&2; fail "$label failed"; }
  for text in "$@"; do
    contains "$output" "$text" || { echo "$output" >&2; fail "$label does not print '$text'"; }
  done
  ok "$label: $*"
}

smoke_test() {
  [ -f "$WOFF2_COMPRESS" ] || fail "missing $WOFF2_COMPRESS, which the smoke tests write a WOFF2 file with"
  chmod +x "$WOFF2_COMPRESS" 2>/dev/null || true

  workdir="smoke-harfbuzz-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  HB_SHAPE="../$(basename "$HB_SHAPE")"
  HB_INFO="../$(basename "$HB_INFO")"
  HB_SUBSET="../$(basename "$HB_SUBSET")"
  HB_VECTOR="../$(basename "$HB_VECTOR")"
  HB_RASTER="../$(basename "$HB_RASTER")"
  WOFF2_COMPRESS="../$(basename "$WOFF2_COMPRESS")"

  # A TrueType font of 1000 units per em and 4 glyphs, which are rectangles:
  #   0 .notdef  advance  500, no outline
  #   1 A        advance  600, 50..550  x 0..700
  #   2 B        advance  700, 50..650  x 0..700
  #   3 A_B      advance 1200, 50..1150 x 0..700
  # GSUB has a `liga` feature that replaces A B with A_B, and GPOS a `kern`
  # feature that moves B 50 units closer to A. scripts/verify-woff2.sh
  # compresses the same font.
  base64 -d > font.ttf <<'EOF'
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
  [ "$(($(wc -c < font.ttf)))" -eq 908 ] || fail "font.ttf was not written correctly"

  # The same font as a WOFF file, whose tables are compressed with zlib.
  base64 -d > font.woff <<'EOF'
d09GRgABAAAAAAM0AAwAAAAAA4wAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAABHUE9TAAACpAAAAEcA
AABWK28kZEdTVUIAAALsAAAARwAAAFYgliVpT1MvMgAAAYwAAAAuAAAAYEUhRM5jbWFwAAABzAAA
ACwAAAA0AAwAlWdseWYAAAIEAAAANAAAAE40cgr/aGVhZAAAARwAAAA2AAAANjGo7SpoaGVhAAAB
VAAAAB8AAAAkB9IEH2htdHgAAAG8AAAAEAAAABALuACWbG9jYQAAAfgAAAAKAAAACgA0ABptYXhw
AAABdAAAABYAAAAgAAYABm5hbWUAAAI4AAAAXgAAAHICv9wRcG9zdAAAApgAAAAMAAAAIAADAAAA
AQAAAAEAAPtKHqxfDzz1AAMD6AAAAADm8VTHAAAAAObxVMcAMgAABH4CvAAAAAMAAgAAAAAAAHic
Y2BkYGBW+G/BwMCygcGIwYiljgEoggJYAEywAvsAeJxjYGRgYGABQhDNwMDEgAYAAUgADQAAeJxj
YGZ6xziBgZWBhYEwYETm2AMBkHJkcGJW+G/BwMCswHACTb0CAxMA9/wFdQAAAfQAAAJYADICvAAy
BLAAMnicY2BgYGJgYGAGYhEgyQimWRgUgDQLEIL4Tv//A0nH////HwDzGQBSqAaeAAAAAAANABoA
JwAAeJxjYGQwYmBgUmPaw8DMwGAsqChoxPiFac9fFwYGiEwXkgxTBJIMSx2SDIsPWAYA5u8Np3ic
LYgxCoAwEAQnURALraysfIGl7wjBDygcIlwVk/97EafY3VmgZcNRcQxfVjydWYNre3tmpn97RtaQ
5Cy35mWXJ0e5ih6JQEI4KdwomYXd/LEVrS/7lYP0AnL9EKIAAHicY2BmwAsAAH0ABHicY2BkYGDg
YlBhMGJgcnHzCWHgy0ksyWPgY2ABijP8/88AkmfMTi3KY+AAscCYhYEJTHMAMQ9YJSODEBBDINP/
cwCw9AkdAHicY2BkYGDgYlBhMGJgcnHzCWHgy0ksyWPgY2ABijP8/88AkmfMyUxPZOAAscCYBSzL
CBRhZBCC0iwMzAxMQMgIggCrSgdAAA==
EOF
  [ "$(($(wc -c < font.woff)))" -eq 820 ] || fail "font.woff was not written correctly"

  # The same font with a `wght` axis from 400, its default, to 900, where A is
  # 200 units wider: its two right-hand points and its advance move by 200.
  base64 -d > variable.ttf <<'EOF'
AAEAAAAOAIAAAwBgR1BPUytvJGQAAAMkAAAAVkdTVUIgliVpAAADfAAAAFZPUy8yRSFEzgAAAWgA
AABgY21hcAAMAJUAAAHYAAAANGZ2YXJ+HWmSAAAD1AAAACRnbHlmNHIK/wAAAhgAAABOZ3Zhcg+r
klYAAAP4AAAANmhlYWQxqO0qAAAA7AAAADZoaGVhB9IEHwAAASQAAAAkaG10eAu4AJYAAAHIAAAA
EGxvY2EANAAaAAACDAAAAAptYXhwAAYABgAAAUgAAAAgbmFtZW+FoZAAAAJoAAAAnHBvc3QAAwAA
AAADBAAAACAAAQAAAAEAADg9zpJfDzz1AAMD6AAAAADm8VTHAAAAAObxVMcAMgAABH4CvAAAAAMA
AgAAAAAAAAABAAADIP84AAAEsAAyADIEfgABAAAAAAAAAAAAAAAAAAAABAABAAAABAAEAAEAAAAA
AAIAAAAAAAAAAAAAAAAAAAAAAAMC7gGQAAUABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAQAAAAAAAAAAAAAAAD8/Pz8AAABBAEIDIP84AAADIADIAAAAAAAAAAAAAAAAAAAAIAAC
AfQAAAJYADICvAAyBLAAMgAAAAIAAAADAAAAFAADAAEAAAAUAAQAIAAAAAQABAABAAAAQv//AAAA
Qf///8AAAQAAAAAAAAAAAA0AGgAnAAAAAQAyAAACJgK8AAMAADMRIREyAfQCvP1EAAABADIAAAKK
ArwAAwAAMxEhETICWAK8/UQAAAEAMgAABH4CvAADAAAzESERMgRMArz9RAAAAAAAAAYATgABAAAA
AAABAA0AAAABAAAAAAACAAcADQABAAAAAAEAAAYAFAADAAEECQABABoAGgADAAEECQACAA4ANAAD
AAEECQEAAAwAQlByZWJ1aWx0IFRlc3RSZWd1bGFyV2VpZ2h0AFAAcgBlAGIAdQBpAGwAdAAgAFQA
ZQBzAHQAUgBlAGcAdQBsAGEAcgBXAGUAaQBnAGgAdAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAEAAAAKACQAMgACREZMVAAObGF0bgAOAAQAAAAA//8AAQAAAAFrZXJuAAgAAAABAAAA
AQAEAAIAAAABAAgAAQAMAAQAAAABABIAAQABAAEAAQAC/84AAAABAAAACgAkADIAAkRGTFQADmxh
dG4ADgAEAAAAAP//AAEAAAABbGlnYQAIAAAAAQAAAAEABAAEAAAAAQAIAAEAEgABAAgAAQAEAAMA
AgACAAEAAQABAAAAAQAAABAAAgABABQAAAAId2dodAGQAAABkAAAA4QAAAAAAQAAAQAAAAEAAAAA
AB4ABAAAAAAAHgAAAAAADAAMAAyAAQAKAAyAAEAAAIFBAMgAyIBAAMiBhwAAAA==
EOF
  [ "$(($(wc -c < variable.ttf)))" -eq 1072 ] || fail "variable.ttf was not written correctly"

  # The same font as a WOFF2 file, whose tables are compressed with brotli.
  cp font.ttf compressed.ttf
  run "woff2_compress" compressed.woff2 "$WOFF2_COMPRESS" compressed.ttf
  [ "$(head -c 4 compressed.woff2)" = "wOF2" ] || fail "compressed.woff2 is not a WOFF2 file"
  ok "wrote the TrueType, WOFF, WOFF2 and variable inputs"

  ligature='[{"g":3,"cl":0,"dx":0,"dy":0,"ax":1200,"ay":0}]'
  kerned='[{"g":1,"cl":0,"dx":0,"dy":0,"ax":550,"ay":0},{"g":2,"cl":1,"dx":0,"dy":0,"ax":700,"ay":0}]'
  right_to_left='[{"g":2,"cl":1,"dx":0,"dy":0,"ax":700,"ay":0},{"g":1,"cl":0,"dx":0,"dy":0,"ax":600,"ay":0}]'
  regular='[{"g":1,"cl":0,"dx":0,"dy":0,"ax":600,"ay":0},{"g":2,"cl":1,"dx":0,"dy":0,"ax":700,"ay":0}]'
  semibold='[{"g":1,"cl":0,"dx":0,"dy":0,"ax":700,"ay":0},{"g":2,"cl":1,"dx":0,"dy":0,"ax":700,"ay":0}]'
  black='[{"g":1,"cl":0,"dx":0,"dy":0,"ax":800,"ay":0},{"g":2,"cl":1,"dx":0,"dy":0,"ax":700,"ay":0}]'

  # Both sets of font functions read the same advances from the same font.
  for funcs in ot ft; do
    msg "hb-shape --font-funcs=$funcs"
    expect_shape "default features: the ligature" "$ligature" --font-funcs="$funcs" font.ttf AB
    expect_shape "--features=-liga: the kerned pair" "$kerned" --font-funcs="$funcs" --features=-liga font.ttf AB
    expect_shape "--direction=rtl --script=Latn --language=en" "$right_to_left" --font-funcs="$funcs" \
      --features=-liga,-kern --direction=rtl --script=Latn --language=en font.ttf AB
    expect_shape "variable font, default instance" "$regular" --font-funcs="$funcs" \
      --features=-liga,-kern variable.ttf AB
    expect_shape "--variations=wght=650" "$semibold" --font-funcs="$funcs" \
      --features=-liga,-kern --variations=wght=650 variable.ttf AB
    expect_shape "--variations=wght=900" "$black" --font-funcs="$funcs" \
      --features=-liga,-kern --variations=wght=900 variable.ttf AB
  done

  # HarfBuzz itself reads neither WOFF nor WOFF2: FreeType does, the first with
  # zlib and the second with brotli.
  msg "WOFF and WOFF2 with --face-loader=ft"
  rejects "WOFF with the ot face loader" "$HB_SHAPE" font.woff AB
  rejects "WOFF2 with the ot face loader" "$HB_SHAPE" compressed.woff2 AB
  ok "the ot face loader reads neither WOFF nor WOFF2"
  for funcs in ot ft; do
    expect_shape "WOFF, --font-funcs=$funcs" "$kerned" --face-loader=ft --font-funcs="$funcs" --features=-liga font.woff AB
    expect_shape "WOFF2, --font-funcs=$funcs" "$kerned" --face-loader=ft --font-funcs="$funcs" --features=-liga compressed.woff2 AB
  done

  msg "hb-info"
  COMMAND="$HB_INFO font.ttf"
  expect_output "hb-info" "Family: Prebuilt Test" "Subfamily: Regular" "Has TrueType outlines" \
    "Has OpenType layout" "Unicode count: 2" "Glyph count: 4" "Units-Per-EM: 1000" "Ascender: 800" "Descender: -200"
  COMMAND="$HB_INFO --list-tables font.ttf"
  expect_output "hb-info --list-tables" "GPOS       86 bytes" "GSUB       86 bytes" "glyf       78 bytes"
  COMMAND="$HB_INFO --list-features font.ttf"
  expect_output "hb-info --list-features" "Feature: liga" "Feature: kern"
  COMMAND="$HB_INFO --list-variations variable.ttf"
  expect_output "hb-info --list-variations" "wght	400	400	900	Weight"
  # These three need HarfBuzz to be built with GObject.
  COMMAND="$HB_INFO --list-metrics font.ttf"
  expect_output "hb-info --list-metrics" "hasc: horizontal-ascender              	800" \
    "hdsc: horizontal-descender             	-200"
  COMMAND="$HB_INFO --list-style font.ttf"
  expect_output "hb-info --list-style" "wght: weight                           	400"
  COMMAND="$HB_INFO --list-baselines font.ttf"
  expect_output "hb-info --list-baselines" "romn: roman                            	0"

  # Keeping A only: B is not in the subset any more, and neither is the ligature.
  msg "hb-subset"
  run "subset" subset.ttf "$HB_SUBSET" font.ttf --unicodes=41 --output-file=subset.ttf
  [ "$(($(wc -c < subset.ttf)))" -lt 908 ] || fail "subset.ttf is not smaller than font.ttf"
  COMMAND="$HB_INFO subset.ttf"
  expect_output "hb-info subset.ttf" "Unicode count: 1" "Glyph count: 2"
  expect_shape "the subset has A and not B" \
    '[{"g":1,"cl":0,"dx":0,"dy":0,"ax":600,"ay":0},{"g":0,"cl":1,"dx":0,"dy":0,"ax":500,"ay":0}]' subset.ttf AB

  # hb-vector draws the outlines the font functions give it.
  msg "hb-vector"
  for funcs in ot ft; do
    run "svg" ligature-$funcs.svg "$HB_VECTOR" --font-funcs="$funcs" --output-file=ligature-$funcs.svg font.ttf AB
    svg="$(cat ligature-$funcs.svg)"
    contains "$svg" '<svg xmlns="http://www.w3.org/2000/svg"' || fail "ligature-$funcs.svg is not an SVG file"
    contains "$svg" '<path d="M50,0L50,700L1150,700L1150,0L50,0Z"' || fail "ligature-$funcs.svg does not have the outline of A_B: $svg"
    run "svg" black-$funcs.svg "$HB_VECTOR" --font-funcs="$funcs" --variations=wght=900 --output-file=black-$funcs.svg variable.ttf A
    svg="$(cat black-$funcs.svg)"
    contains "$svg" '<path d="M50,0L50,700L750,700L750,0L50,0Z"' || fail "black-$funcs.svg does not have the outline of A at wght=900: $svg"
    ok "--font-funcs=$funcs: SVG outlines of the ligature and of A at wght=900"
  done
  run "pdf" ligature.pdf "$HB_VECTOR" --output-format=pdf --output-file=ligature.pdf font.ttf AB
  [ "$(head -c 5 ligature.pdf)" = "%PDF-" ] || fail "ligature.pdf is not a PDF file"
  ok "--output-format=pdf"

  msg "hb-raster"
  run "png" ligature.png "$HB_RASTER" --output-file=ligature.png font.ttf AB
  [ "$(head -c 4 ligature.png | tail -c 3)" = "PNG" ] || fail "ligature.png is not a PNG file"
  run "ppm" ligature.ppm "$HB_RASTER" --output-format=ppm --output-file=ligature.ppm font.ttf AB
  [ "$(head -c 2 ligature.ppm)" = "P6" ] || fail "ligature.ppm is not a PPM file"
  ok "PNG and PPM output"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$HB_SHAPE"
    assert_linkage "$HB_INFO"
    assert_linkage "$HB_SUBSET"
    assert_linkage "$HB_VECTOR"
    assert_linkage "$HB_RASTER"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    assert_version hb-shape "$HB_SHAPE"
    assert_version hb-info "$HB_INFO"
    assert_version hb-subset "$HB_SUBSET"
    assert_version hb-vector "$HB_VECTOR"
    assert_version hb-raster "$HB_RASTER"
    # No target is built with the shapers and the font functions of a platform,
    # so that every target gives the same results.
    msg "shapers, font functions and face loaders"
    assert_list hb-shape "$HB_SHAPE" --list-shapers "ot fallback" "coretext directwrite uniscribe graphite2"
    assert_list hb-shape "$HB_SHAPE" --list-font-funcs "ot ft" "coretext directwrite"
    assert_list hb-shape "$HB_SHAPE" --list-face-loaders "ot ft" "coretext directwrite gdi"
    assert_list hb-vector "$HB_VECTOR" --list-font-funcs "ot ft" "coretext directwrite"
    assert_list hb-raster "$HB_RASTER" --list-font-funcs "ot ft" "coretext directwrite"
    msg "command-line options"
    assert_options hb-shape "$HB_SHAPE" --shapers= --output-format= --no-glyph-names --features= --variations= \
      --language= --script= --direction= --font-funcs= --face-loader=
    assert_options hb-info "$HB_INFO" --list-style --list-metrics --list-baselines --list-variations
    assert_options hb-vector "$HB_VECTOR" --output-format= --font-funcs= --variations=
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
