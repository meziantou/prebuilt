#!/usr/bin/env bash
#
# Verifies a custom ffmpeg/ffprobe pair.
#
#   bash scripts/verify-ffmpeg.sh <target> <mode>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | win-arm64 | osx-arm64
# Modes:
#   link  static-linkage assertions only (runs on the build host; the Windows
#         targets are cross-compiled, so this uses the cross objdump)
#   run   -buildconf / encoder / decoder assertions plus real encode+probe
#         smoke tests (must run on the target platform)
#   all   both
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64) EXE=""; CROSS_PREFIX="" ;;
  win-x64)   EXE=".exe"; CROSS_PREFIX="x86_64-w64-mingw32-" ;;
  win-arm64) EXE=".exe"; CROSS_PREFIX="aarch64-w64-mingw32-" ;;
  osx-arm64) EXE=""; CROSS_PREFIX="" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

FFMPEG="./ffmpeg-custom-$TARGET$EXE"
FFPROBE="./ffprobe-custom-$TARGET$EXE"
[ -f "$FFMPEG" ] || { echo "missing $FFMPEG" >&2; exit 1; }
[ -f "$FFPROBE" ] || { echo "missing $FFPROBE" >&2; exit 1; }
chmod +x "$FFMPEG" "$FFPROBE" 2>/dev/null || true

msg()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Linkage
# ---------------------------------------------------------------------------

assert_linkage() {
  bin="$1"
  case "$TARGET" in
    linux-*)
      file "$bin" | grep -q 'statically linked' \
        || fail "$bin is not statically linked: $(file "$bin")"
      # ldd exits non-zero on a static binary, hence the `|| true`.
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
      imports="$("${CROSS_PREFIX}objdump" -p "$bin" | sed -n 's/^[[:space:]]*DLL Name: //p' \
                 | tr 'A-Z' 'a-z' | sort -u)"
      bad=""
      for dll in $imports; do
        # Allowlist of DLLs that ship with Windows itself. Anything outside it
        # means a dependency leaked in dynamically -- most likely libc++.dll,
        # libwinpthread-1.dll or a codec DLL. avicap32/vfw32/msacm32 come from
        # ffmpeg's vfwcap indev; the d3d/mf/dxva entries from optional hwaccels;
        # ucrtbase and the api-ms-win-crt-* stubs are the UCRT, a Windows
        # component since Windows 10.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|advapi32.dll|shell32.dll|shlwapi.dll|ole32.dll|oleaut32.dll|gdi32.dll|imm32.dll|version.dll|userenv.dll|setupapi.dll|cfgmgr32.dll|psapi.dll|iphlpapi.dll|ws2_32.dll|secur32.dll|bcrypt.dll|crypt32.dll|winmm.dll|avicap32.dll|vfw32.dll|msacm32.dll|mfplat.dll|mf.dll|mfreadwrite.dll|strmiids.dll|dxva2.dll|dxgi.dll|d3d9.dll|d3d11.dll|msvcrt.dll|ucrtbase.dll|api-ms-win-*|vcruntime*) ;;
          *) bad="$bad $dll" ;;
        esac
      done
      [ -z "$bad" ] || fail "$bin imports non-system DLLs:$bad"
      ok "$bin imports only system DLLs ($(echo $imports | tr ' ' ',' ))"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Feature assertions
# ---------------------------------------------------------------------------

assert_buildconf() {
  conf="$("$FFMPEG" -hide_banner -buildconf 2>&1)"
  for opt in --enable-gpl --enable-zlib --enable-libx264 --enable-libx265 \
             --enable-libvpx --enable-libaom --enable-libsvtav1 --enable-libdav1d \
             --enable-libjxl --enable-libwebp --enable-libopus; do
    echo "$conf" | grep -q -- "$opt" || fail "missing configure option: $opt"
  done
  ok "buildconf contains every expected --enable-* option"

  # --disable-autodetect also turns off threading; a single-threaded ffmpeg
  # would still build and pass every encode test, just very slowly.
  echo "$conf" | grep -qE -- '--enable-(pthreads|w32threads)' \
    || fail "threading is disabled (--disable-autodetect side effect)"
  ok "threading is enabled"
}

assert_codecs() {
  encoders="$("$FFMPEG" -hide_banner -encoders 2>&1)"
  for e in libx264 libx265 libvpx-vp9 libaom-av1 libsvtav1 libjxl libwebp libopus png mjpeg aac; do
    echo "$encoders" | grep -q " $e " || fail "missing encoder: $e"
  done
  ok "all expected encoders present"

  decoders="$("$FFMPEG" -hide_banner -decoders 2>&1)"
  for d in libdav1d png mjpeg webp h264 hevc vp9 opus aac libjxl; do
    echo "$decoders" | grep -q " $d " || fail "missing decoder: $d"
  done
  ok "all expected decoders present"
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

probe_codec() {
  # No `head -1` anywhere in this script: it closes the pipe early, the writer
  # takes SIGPIPE, and `set -o pipefail` turns that into a spurious exit 141.
  "$FFPROBE" -v quiet -print_format json -show_streams "$1" \
    | tr -d ' "' | sed -n 's/^codec_name:\(.*\),$/\1/p' | sed -n 1p
}

assert_probe() {
  file="$1"; expected="$2"
  actual="$(probe_codec "$file")"
  [ "$actual" = "$expected" ] || fail "$file: expected codec_name '$expected', got '$actual'"
  ok "$file probes as $expected"
}

encode() {
  label="$1"; out="$2"; shift 2
  rm -f "$out"
  "$FFMPEG" -hide_banner -v error -y "$@" "$out" || fail "$label encode failed"
  [ -s "$out" ] || fail "$label produced an empty file"
}

smoke_test() {
  workdir="smoke-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  FFMPEG="../$(basename "$FFMPEG")"
  FFPROBE="../$(basename "$FFPROBE")"

  # A 16x16 ASCII PPM, scaled up by ffmpeg. image2 is always available, unlike
  # the lavfi input device.
  {
    echo "P3"; echo "16 16"; echo "255"
    y=0
    while [ "$y" -lt 16 ]; do
      x=0
      while [ "$x" -lt 16 ]; do
        printf '%d %d %d ' $((x * 16)) $((y * 16)) $(((x + y) * 8))
        x=$((x + 1))
      done
      echo
      y=$((y + 1))
    done
  } > input.ppm

  SRC="-loop 1 -i input.ppm -t 1 -r 10"
  VF="scale=64:64,format=yuv420p"

  msg "still images"
  encode AVIF out.avif -i input.ppm -frames:v 1 -c:v libaom-av1 -still-picture 1 -cpu-used 8 -row-mt 1 -vf "$VF"
  assert_probe out.avif av1
  encode JXL  out.jxl  -i input.ppm -frames:v 1 -c:v libjxl -effort 3 -vf "scale=64:64"
  encode WebP out.webp -i input.ppm -frames:v 1 -c:v libwebp -compression_level 4 -vf "$VF"
  assert_probe out.webp webp
  encode PNG  out.png  -i input.ppm -frames:v 1 -c:v png
  assert_probe out.png png

  msg "video"
  encode VP9    vp9.webm  $SRC -c:v libvpx-vp9 -b:v 0 -crf 50 -cpu-used 8 -vf "$VF" -f webm
  assert_probe vp9.webm vp9
  encode SVT-AV1 av1.mp4  $SRC -c:v libsvtav1 -crf 50 -preset 12 -vf "$VF" -f mp4
  assert_probe av1.mp4 av1
  encode x264   h264.mp4  $SRC -c:v libx264 -preset ultrafast -crf 30 -vf "$VF" -f mp4
  assert_probe h264.mp4 h264
  encode x265   h265.mp4  $SRC -c:v libx265 -preset ultrafast -crf 30 -vf "$VF" -f mp4 -tag:v hvc1
  assert_probe h265.mp4 hevc

  msg "audio"
  encode Opus opus.webm -f lavfi -i "sine=frequency=440:duration=1" -c:a libopus -f webm
  assert_probe opus.webm opus

  msg "decode round-trip"
  # The site re-feeds existing .avif and .webp assets back into ffmpeg.
  encode "AVIF decode" from-avif.png -i out.avif -frames:v 1 -c:v png
  encode "WebP decode" from-webp.png -i out.webp -frames:v 1 -c:v png

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$FFMPEG"
    assert_linkage "$FFPROBE"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    ffmpeg_version="$("$FFMPEG" -hide_banner -version)"
    ffprobe_version="$("$FFPROBE" -hide_banner -version)"
    echo "${ffmpeg_version%%$'\n'*}"
    echo "${ffprobe_version%%$'\n'*}"
    msg "configuration"
    assert_buildconf
    assert_codecs
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
