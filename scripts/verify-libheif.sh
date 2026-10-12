#!/usr/bin/env bash
#
# Verifies the dec265/heif-enc/heif-dec/heif-info set built by
# scripts/build-libheif.sh.
#
#   bash scripts/verify-libheif.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version and codec assertions plus real decodes and encode+decode
#         round-trips (must run on the target platform)
#   all   both (default)
#
# The tools are published as references for HEVC and HEIC, so the codecs are
# asserted as strictly as the versions: x265 is the only encoder, libde265 the
# only decoder, and nothing else is compiled in.
#
# The pictures are compared sample by sample in scripts/verify-hevc.sh, which
# has ffmpeg to read the PNG files heif-dec writes and to write streams for
# dec265. Here dec265 decodes two streams stored in this script, and the files
# of the heif tools are checked through heif-info and the header of the PNG
# files.
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

DEC265="./dec265-$TARGET$EXE"
HEIF_ENC="./heif-enc-$TARGET$EXE"
HEIF_DEC="./heif-dec-$TARGET$EXE"
HEIF_INFO="./heif-info-$TARGET$EXE"
for bin in "$DEC265" "$HEIF_ENC" "$HEIF_DEC" "$HEIF_INFO"; do
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
# Version and codecs
# ---------------------------------------------------------------------------

# dec265 has no --version: its help starts with " dec265  v1.1.3", on stderr.
assert_dec265() {
  help="$("$DEC265" -h 2>&1 | tr -d '\r')" || fail "dec265 -h failed: $help"
  contains "$help" "dec265  v" || { echo "$help" >&2; fail "dec265 does not print its version"; }
  if [ -n "$LIBDE265_VERSION" ]; then
    contains "$help" "dec265  v$LIBDE265_VERSION
" || fail "dec265 does not report version $LIBDE265_VERSION: $help"
    ok "dec265 reports version $LIBDE265_VERSION"
  else
    echo "  LIBDE265_VERSION is not set; skipping the dec265 version check"
  fi
  for option in "-t, --threads N   set number of worker threads (0 - no threading)" \
                "-c, --check-hash" "-o, --output" "-n, --nal"; do
    contains "$help" "$option" || fail "dec265 has no option '$option'"
  done
  ok "dec265 has --threads, --check-hash, --output and --nal"
  # dec265 displays the pictures with SDL or videogfx when it is built with
  # them; -V selects videogfx.
  if contains "$help" "videogfx" || contains "$help" "-V,"; then
    fail "dec265 is built with videogfx: $help"
  fi
  ok "dec265 is built without videogfx"
}

# The three heif tools print the same thing:
#   1.23.6
#   libheif: 1.23.6
#   plugin path: plugins are disabled
assert_heif_version() {
  tool="$1"; bin="$2"
  banner="$("$bin" --version 2>&1 | tr -d '\r')" || fail "$tool --version failed: $banner"
  if [ -n "$LIBHEIF_VERSION" ]; then
    contains "$banner
" "libheif: $LIBHEIF_VERSION
" || fail "$tool does not report libheif $LIBHEIF_VERSION: $banner"
    [ "${banner%%$'\n'*}" = "$LIBHEIF_VERSION" ] || fail "$tool does not report version $LIBHEIF_VERSION: $banner"
    ok "$tool reports version $LIBHEIF_VERSION"
  else
    echo "  LIBHEIF_VERSION is not set; skipping the $tool version check"
  fi
  contains "$banner" "plugin path: plugins are disabled" || fail "$tool loads plugins: $banner"
  ok "$tool does not load plugins"
}

# list_entries <text>: the "- id = name" lines of --list-encoders and
# --list-decoders, which print a heading for every format, with or without a
# codec under it.
list_entries() {
  echo "$1" | sed -n 's/^- //p'
}

assert_codecs() {
  list="$("$HEIF_ENC" --list-encoders 2>&1 | tr -d '\r')" || fail "heif-enc --list-encoders failed: $list"
  echo "$list"
  entries="$(list_entries "$list")"
  case "$entries" in
    *"
"*) fail "heif-enc has more than one encoder: $entries" ;;
    "x265 = x265 HEVC encoder ("*") [default]") ;;
    *) fail "the encoder of heif-enc is not x265: $entries" ;;
  esac
  contains "$list" "HEIC encoders:
- x265 = " || fail "x265 is not listed as a HEIC encoder"
  ok "x265 is the only encoder of heif-enc"
  if [ -n "$X265_VERSION" ]; then
    contains "$entries" "x265 HEVC encoder ($X265_VERSION+" || fail "heif-enc is not linked with x265 $X265_VERSION: $entries"
    ok "heif-enc is linked with x265 $X265_VERSION"
  else
    echo "  X265_VERSION is not set; skipping the x265 version check"
  fi

  list="$("$HEIF_DEC" --list-decoders 2>&1 | tr -d '\r')" || fail "heif-dec --list-decoders failed: $list"
  echo "$list"
  entries="$(list_entries "$list")"
  case "$entries" in
    *"
"*) fail "heif-dec has more than one decoder: $entries" ;;
    "libde265 = libde265 HEVC decoder, version "*) ;;
    *) fail "the decoder of heif-dec is not libde265: $entries" ;;
  esac
  contains "$list" "HEIC decoders:
- libde265 = " || fail "libde265 is not listed as a HEIC decoder"
  ok "libde265 is the only decoder of heif-dec"
  if [ -n "$LIBDE265_VERSION" ]; then
    [ "$entries" = "libde265 = libde265 HEVC decoder, version $LIBDE265_VERSION" ] \
      || fail "heif-dec is not linked with libde265 $LIBDE265_VERSION: $entries"
    ok "heif-dec is linked with libde265 $LIBDE265_VERSION"
  fi

  # The chroma formats and the lossless mode of the x265 plugin, and the
  # options of the features the tools are published for.
  parameters="$("$HEIF_ENC" -P 2>&1 | tr -d '\r')" || fail "heif-enc -P failed: $parameters"
  contains "$parameters" "chroma, default=420, { 420,422,444 }" || fail "heif-enc does not encode 4:2:0, 4:2:2 and 4:4:4: $parameters"
  contains "$parameters" "lossless, default=false" || fail "heif-enc has no lossless parameter: $parameters"
  help="$("$HEIF_ENC" --help 2>&1 | tr -d '\r')" || true
  for option in "-b, --bit-depth" "-L, --lossless" "--cut-tiles" "-T, --tiled-input" "-S, --sequence"; do
    contains "$help" "$option" || fail "heif-enc has no option '$option'"
  done
  help="$("$HEIF_DEC" --help 2>&1 | tr -d '\r')" || true
  contains "$help" "These suffixes are recognized: png, y4m." || fail "heif-dec does not write PNG and Y4M alone: $help"
  contains "$help" "-S, --sequence" || fail "heif-dec has no option '-S, --sequence'"
  ok "heif-enc and heif-dec have the lossless, bit depth, tile and sequence options, and PNG"
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

# sized <file> <bytes>: the file was written correctly.
sized() {
  [ "$(($(wc -c < "$1")))" -eq "$2" ] || fail "$1 was not written correctly"
}

# checksum <file>: the CRC and the size of the file, as POSIX cksum prints them.
checksum() {
  cksum < "$1" | tr -s ' \t' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# decodes <stream> <bytes> <CRC>: dec265 decodes the stream on one thread,
# checks the hash of every picture, and writes the expected samples.
decodes() {
  stream="$1"
  run "$stream" "$stream.yuv" "$DEC265" -q -t 0 -c -o "$stream.yuv" "$stream"
  [ "$(checksum "$stream.yuv")" = "$3 $2" ] \
    || fail "$stream: dec265 wrote $(checksum "$stream.yuv") (CRC, bytes) instead of $3 $2"
  ok "$stream: dec265 checks the picture hashes and writes the expected $2 bytes"
}

# expect_info <file> <text>...: every text is in the output of heif-info.
expect_info() {
  file="$1"; shift
  info="$("$HEIF_INFO" "$file" 2>&1 | tr -d '\r')" || { echo "$info" >&2; fail "heif-info $file failed"; }
  for text in "$@"; do
    contains "$info" "$text" || { echo "$info" >&2; fail "$file: heif-info does not report '$text'"; }
  done
  ok "$file: $*"
}

# expect_png <file> <width> <height> <bits> <colour type>: the header of the
# PNG file. Colour type 2 is RGB, 6 is RGB with alpha.
expect_png() {
  [ "$(od -An -tx1 -N 8 "$1" | tr -d ' \n\r')" = "89504e470d0a1a0a" ] || fail "$1 is not a PNG file"
  printf -v header '%08x%08x%02x%02x' "$2" "$3" "$4" "$5"
  actual="$(od -An -tx1 -j 16 -N 10 "$1" | tr -d ' \n\r')"
  [ "$actual" = "$header" ] || fail "$1 is not a $2x$3 PNG of $4 bits and colour type $5: $actual"
  ok "$1 is a $2x$3 PNG of $4 bits per sample"
}

smoke_test() {
  workdir="smoke-libheif-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  DEC265="../$(basename "$DEC265")"
  HEIF_ENC="../$(basename "$HEIF_ENC")"
  HEIF_DEC="../$(basename "$HEIF_DEC")"
  HEIF_INFO="../$(basename "$HEIF_INFO")"

  msg "dec265"
  # Two raw (Annex B) streams of two 16x16 pictures, an I and a P picture,
  # written by x265 with an MD5 of every decoded picture (hash=1):
  # 8 bits 4:2:0, and 12 bits 4:4:4 of the range extensions.
  base64 -d > main.hevc <<'EOF'
AAAAAUABDAH//wFgAAADAJAAAAMAAAMAHpKAkAAAAAFCAQEBYAAAAwCQAAADAAADAB6giEWWSqvK
5oCAAAADAIAAAAyEAAAAAUQBwXPQiQAAASgBrx2A8CC1VcHgzJIlh7rByVvSOAAAAVABhDEAoUZS
2pxGSZjwo8FoSfp781cml2fDhP8npTDqOY3o/4HvyVNukGjup41+GEwTrokCgAAAAAECAdAJfhDG
O+r097M0HgAAAVABhDEAUtvgHU4B8wEbBvMIcLOFX62S2mVJo471NpgL6Fz9uyVSvlbsPBhoLugt
aNRALApHgA==
EOF
  sized main.hevc 235
  base64 -d > rext.hevc <<'EOF'
AAAAAUABDAH//wQIAAADAJgIAAADAAAekoCQAAAAAUIBAQQIAAADAJgIAAADAAAekBEIilLJVXlc
0BAAAAMAEAAAAwGQgAAAAAFEAcFzGDEIkAAAASgBrx2A8Bs1VcHRRY4ogEIlStzgAAABUAGEMQAN
JG7gTMEZF4fdEhi78yEm1hf7pEgtVPbIXhl8HwDf9nFH1iKEQR0QHaqOsWGV+2WAAAAAAQIB0Al+
EMY76vSOErd3AAABUAGEMQBEXreAjklGYtzqY08z2xRs7Y5Zi4Gp5BXMO7+lhpGoLCo8R89Ait/p
a3GLs1IqvhOA
EOF
  sized rext.hevc 237
  # 2 pictures of 16x16 samples and two 8x8 chroma planes, one byte a sample;
  # 2 pictures of three 16x16 planes, two bytes a sample (little endian).
  decodes main.hevc 768 691463670
  decodes rext.hevc 3072 206978989

  # --check-hash is what tells a wrong picture from a right one. One byte of
  # the MD5 of the last picture is changed: the pictures still decode, and
  # only -c reports them.
  position="$(($(wc -c < main.hevc) - 47))"
  [ "$(od -An -tx1 -j $((position - 10)) -N 5 main.hevc | tr -d ' \n\r')" = "0000015001" ] \
    || fail "main.hevc does not end with the hash of its last picture"
  printf -v changed '\\%03o' $((0x$(od -An -tx1 -j "$position" -N 1 main.hevc | tr -d ' \n\r') ^ 255))
  # shellcheck disable=SC2059
  { head -c "$position" main.hevc; printf "$changed"; tail -c 46 main.hevc; } > wrong-hash.hevc
  sized wrong-hash.hevc 235
  run "without --check-hash" unchecked.yuv "$DEC265" -q -t 0 -o unchecked.yuv wrong-hash.hevc
  cmp -s unchecked.yuv main.hevc.yuv || fail "wrong-hash.hevc does not decode to the pictures of main.hevc"
  status=0
  "$DEC265" -q -t 0 -c -o checked.yuv wrong-hash.hevc > tool.log 2>&1 || status=$?
  [ "$status" -ne 0 ] || { cat tool.log >&2; fail "dec265 --check-hash accepted a wrong hash"; }
  contains "$(cat tool.log)" "image checksum mismatch" || { cat tool.log >&2; fail "dec265 --check-hash does not report the mismatch"; }
  ok "dec265 --check-hash rejects a picture whose hash is wrong"

  msg "PNG inputs"
  # Ramps, 64x48: 8 bits RGB, 16 bits RGB and 8 bits RGB with alpha. The
  # samples of the 16-bit file only use their 10 high bits, so that a 10 or a
  # 12-bit file holds them exactly. And 128x128, to cut into tiles.
  base64 -d > rgb8.png <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAEAAAAAwCAIAAAAuKetIAAAASUlEQVR42u3PAQkAIAwAMPUeqzyO
/dPYQjgMVmBz1I08fa3c0ZqAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDAPw/RZJGJ
qBdf1gAAAABJRU5ErkJggg==
EOF
  sized rgb8.png 130
  base64 -d > rgb16.png <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAEAAAAAwEAIAAAB+uTcLAAAApklEQVR42u3VQQqAIBRFUVPb15+3
v9bT0koDadqgnBwCiZuzHpwlpS3tqUQ5apSo47yeYw39657bS26f+9ne+7XQ/+njB9ypPq7qf/Rs
lXN7tsq5nQEMYIBVMoABVskABlglAxhglQxggLUygAHWygAG6AxggM4ABugMYIDOAAboDGCAzgAG
6AxggM4ABugMYIDOAAboDGCAzgAG6AxggM4ABugv+glwG5Xb9KvClQAAAABJRU5ErkJggg==
EOF
  sized rgb16.png 223
  base64 -d > rgba8.png <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAEAAAAAwCAYAAAChS3wfAAAAW0lEQVR42u3QQREAIAgAMFA4qxjH
/mnsoXuswDL2idmrfjW6Zv5MgAABAgQIECBAgAABAgQIECBAgAABAgQIECBAgAABAgQIECBAgAAB
AgQIECBAgAABAgS86AKQL55FLXB8cgAAAABJRU5ErkJggg==
EOF
  sized rgba8.png 148
  base64 -d > tiles8.png <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAIAAABMXPacAAAAyklEQVR42u3RwQ0AMAwCMWj237mV
OkQ+FjcBbpKe0VZv1WIAAAAQAAACAEAAAAgAAAEAIAAABACAAAAQAAACAEAAAAgAAAEAIAAABACA
AAAQAAACAEAAAAgAAAEAIAAABACAAAAQAAACAEAAAAgAAAEAIAAABAAAABcAACAAAAQAgAAAEAAA
AgBAAAAIAAABACAAAAQAgAAAEAAAAgBAAAAIAAABACAAAAQAgAAAEAAAAgBAAAAIAAABACAAAAQA
gAAAEAAAAgBAvwt3GYEJZJH91wAAAABJRU5ErkJggg==
EOF
  sized tiles8.png 259
  ok "wrote the PNG inputs"

  msg "8 bits"
  run "lossy" lossy8.heic "$HEIF_ENC" rgb8.png -o lossy8.heic
  expect_info lossy8.heic "MIME type: image/heic" "main brand: heic" "image: 64x48" \
    "colorspace: YCbCr, 4:2:0" "bit depth: 8" "alpha channel: no"
  run "decode" lossy8.png "$HEIF_DEC" lossy8.heic lossy8.png
  expect_png lossy8.png 64 48 8 2
  run "decode to Y4M" lossy8.y4m "$HEIF_DEC" lossy8.heic lossy8.y4m
  [ "$(head -c 17 lossy8.y4m)" = "YUV4MPEG2 W64 H48" ] || fail "lossy8.y4m is not a 64x48 Y4M file"
  ok "lossy8.y4m is a 64x48 Y4M file"
  run "4:2:2" chroma422.heic "$HEIF_ENC" -p chroma=422 rgb8.png -o chroma422.heic
  expect_info chroma422.heic "colorspace: YCbCr, 4:2:2" "bit depth: 8"
  run "4:4:4" chroma444.heic "$HEIF_ENC" -p chroma=444 rgb8.png -o chroma444.heic
  expect_info chroma444.heic "colorspace: YCbCr, 4:4:4" "bit depth: 8"
  run "lossless" lossless8.heic "$HEIF_ENC" -L rgb8.png -o lossless8.heic
  expect_info lossless8.heic "colorspace: RGB" "bit depth: 8" "matrix coefficients: 0 (RGB/GBR)"
  run "decode" lossless8.png "$HEIF_DEC" lossless8.heic lossless8.png
  expect_png lossless8.png 64 48 8 2

  # A 16-bit PNG is encoded with 10 bits unless -b says otherwise, and decoded
  # to a 16-bit PNG.
  msg "10 and 12 bits"
  run "10 bits by default" default10.heic "$HEIF_ENC" rgb16.png -o default10.heic
  expect_info default10.heic "main brand: heix" "colorspace: YCbCr, 4:2:0" "bit depth: 10"
  run "10 bits" lossless10.heic "$HEIF_ENC" -L -b 10 rgb16.png -o lossless10.heic
  expect_info lossless10.heic "colorspace: RGB" "bit depth: 10"
  run "decode" lossless10.png "$HEIF_DEC" lossless10.heic lossless10.png
  expect_png lossless10.png 64 48 16 2
  run "12 bits" lossless12.heic "$HEIF_ENC" -L -b 12 rgb16.png -o lossless12.heic
  expect_info lossless12.heic "colorspace: RGB" "bit depth: 12"
  run "decode" lossless12.png "$HEIF_DEC" lossless12.heic lossless12.png
  expect_png lossless12.png 64 48 16 2
  run "12 bits 4:2:2" lossy12.heic "$HEIF_ENC" -b 12 -p chroma=422 rgb16.png -o lossy12.heic
  expect_info lossy12.heic "colorspace: YCbCr, 4:2:2" "bit depth: 12"
  run "decode" lossy12.png "$HEIF_DEC" lossy12.heic lossy12.png
  expect_png lossy12.png 64 48 16 2

  msg "alpha"
  run "alpha" alpha.heic "$HEIF_ENC" rgba8.png -o alpha.heic
  expect_info alpha.heic "image: 64x48" "alpha channel: yes"
  run "decode" alpha.png "$HEIF_DEC" alpha.heic alpha.png
  expect_png alpha.png 64 48 8 6

  # A grid image: four 64x64 HEVC images and the item that puts them together.
  msg "tiles"
  run "grid" grid.heic "$HEIF_ENC" --cut-tiles 64 tiles8.png -o grid.heic
  expect_info grid.heic "image: 128x128" "tiles: 2x2, tile size: 64x64"
  boxes="$("$HEIF_INFO" -d grid.heic 2>&1 | tr -d '\r')" || fail "heif-info -d grid.heic failed"
  contains "$boxes" "item_type: grid" || fail "grid.heic has no grid item"
  [ "$(echo "$boxes" | grep -c 'item_type: hvc1')" -eq 4 ] || fail "grid.heic does not have 4 HEVC items"
  ok "grid.heic: a grid item of 4 HEVC items"
  run "decode" grid.png "$HEIF_DEC" grid.heic grid.png
  expect_png grid.png 128 128 8 2

  # An image sequence: a track of HEVC samples next to the primary image.
  # The pictures are 128x128: x265 codes a 64x48 picture as 64x64, and where
  # the image item of a still picture is cropped, heif-dec writes the samples
  # of a track as they are coded.
  msg "sequences"
  cp tiles8.png frame-01.png
  cp grid.png frame-02.png
  cp tiles8.png frame-03.png
  run "sequence" sequence.heic "$HEIF_ENC" -S frame-01.png -o sequence.heic
  expect_info sequence.heic "MIME type: image/heic-sequence" "handler: 'pict' = image sequence" \
    "resolution: 128x128" "sample entry type: hvc1"
  run "decode the sequence" sequence-3.png "$HEIF_DEC" -S sequence.heic sequence.png
  [ -s sequence-1.png ] && [ -s sequence-2.png ] && [ ! -e sequence-4.png ] || fail "sequence.heic does not decode to 3 pictures"
  expect_png sequence-3.png 128 128 8 2

  # Without a JPEG library, the default output format of heif-dec cannot be
  # written, and HEVC is the only format heif-enc writes.
  msg "no other codec"
  status=0
  "$HEIF_DEC" lossy8.heic lossy8.jpg > tool.log 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "heif-dec wrote a JPEG file"
  contains "$(cat tool.log)" "JPEG support has not been compiled in." \
    || { cat tool.log >&2; fail "heif-dec does not say it has no JPEG support"; }
  for format in jpeg avif avc vvc jpeg2000 htj2k; do
    status=0
    "$HEIF_ENC" "--$format" rgb8.png -o "other.$format" > tool.log 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail "heif-enc --$format wrote a file"
  done
  ok "heif-dec has no JPEG output, heif-enc no encoder but HEVC"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$DEC265"
    assert_linkage "$HEIF_ENC"
    assert_linkage "$HEIF_DEC"
    assert_linkage "$HEIF_INFO"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    assert_dec265
    assert_heif_version heif-enc "$HEIF_ENC"
    assert_heif_version heif-dec "$HEIF_DEC"
    assert_heif_version heif-info "$HEIF_INFO"
    msg "codecs"
    assert_codecs
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
