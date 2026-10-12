#!/usr/bin/env bash
#
# Verifies an ffmpeg/ffprobe pair built by scripts/build-ffmpeg.sh, and the
# x265 and kvazaar tools built with them.
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

FFMPEG="./ffmpeg-$TARGET$EXE"
FFPROBE="./ffprobe-$TARGET$EXE"
X265="./x265-$TARGET$EXE"
KVAZAAR="./kvazaar-$TARGET$EXE"
for bin in "$FFMPEG" "$FFPROBE" "$X265" "$KVAZAAR"; do
  [ -f "$bin" ] || { echo "missing $bin" >&2; exit 1; }
  chmod +x "$bin" 2>/dev/null || true
done

# The test pictures are written byte by byte with printf.
export LC_ALL=C
# Git Bash on Windows rewrites arguments that look like POSIX paths.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

msg()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m %s\n' "$*"; }

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

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

# Without a VERSION file in the source tree, ffmpeg stamps itself with
# `git describe` of whatever repository the sources were extracted in.
assert_version() {
  tool="$1"; banner="$2"
  if [ -z "$FFMPEG_VERSION" ]; then
    echo "  FFMPEG_VERSION is not set; skipping the $tool version check"
    return 0
  fi
  case "$banner" in
    "$tool version $FFMPEG_VERSION "*) ok "$tool reports version $FFMPEG_VERSION" ;;
    *) fail "$tool does not report version $FFMPEG_VERSION: $banner" ;;
  esac
}

assert_buildconf() {
  conf="$("$FFMPEG" -hide_banner -buildconf 2>&1)"
  for opt in --enable-gpl --enable-zlib --enable-libx264 --enable-libx265 --enable-libkvazaar \
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
  for e in libx264 libx265 libkvazaar libvpx-vp9 libaom-av1 libsvtav1 libjxl libwebp libopus png mjpeg aac; do
    echo "$encoders" | grep -q " $e " || fail "missing encoder: $e"
  done
  ok "all expected encoders present"

  decoders="$("$FFMPEG" -hide_banner -decoders 2>&1)"
  for d in libdav1d png mjpeg webp h264 hevc vp9 opus aac libjxl; do
    echo "$decoders" | grep -q " $d " || fail "missing decoder: $d"
  done
  ok "all expected decoders present"
}

# What the HEVC tests of the consumers of this build rely on.
assert_hevc() {
  # libx265 is linked for 8, 10 and 12 bits: an 8-bit only x265 lists the
  # first six formats and yuva420p.
  help="$("$FFMPEG" -hide_banner -h encoder=libx265 2>&1 | tr -d '\r')"
  formats=" $(echo "$help" | sed -n 's/^ *Supported pixel formats: *//p') "
  for format in yuv420p yuv422p yuv444p gbrp gray \
                yuv420p10le yuv422p10le yuv444p10le gbrp10le gray10le \
                yuv420p12le yuv422p12le yuv444p12le gbrp12le gray12le; do
    contains "$formats" " $format " || fail "libx265 does not encode $format:$formats"
  done
  ok "libx265 encodes 8, 10 and 12 bits"

  # libkvazaar is compiled for 8 bits, and ffmpeg only gives it 4:2:0.
  help="$("$FFMPEG" -hide_banner -h encoder=libkvazaar 2>&1 | tr -d '\r')"
  formats=" $(echo "$help" | sed -n 's/^ *Supported pixel formats: *//p') "
  contains "$formats" " yuv420p " || fail "libkvazaar does not encode yuv420p:$formats"
  ok "libkvazaar encodes yuv420p"

  help="$("$FFMPEG" -hide_banner -h decoder=hevc 2>&1)"
  contains "$help" "Decoder hevc [" || fail "missing the native hevc decoder"
  for muxer in hevc mov mp4; do
    help="$("$FFMPEG" -hide_banner -h muxer="$muxer" 2>&1)"
    contains "$help" "Muxer $muxer [" || fail "missing muxer: $muxer"
  done
  for demuxer in hevc mov; do
    help="$("$FFMPEG" -hide_banner -h demuxer="$demuxer" 2>&1)"
    contains "$help" "Demuxer $demuxer" || fail "missing demuxer: $demuxer"
  done
  ok "hevc decoder, hevc, mov and mp4 muxers, hevc and mov demuxers present"

  for bsf in hevc_metadata hevc_mp4toannexb trace_headers filter_units; do
    help="$("$FFMPEG" -hide_banner -h bsf="$bsf" 2>&1)"
    contains "$help" "Bit stream filter $bsf" || fail "missing bitstream filter: $bsf"
  done
  ok "hevc_metadata, hevc_mp4toannexb, trace_headers and filter_units bitstream filters present"
}

# x265 prints its version on stderr:
#   x265 [info]: HEVC encoder version 4.2+1-e444744
#   x265 [info]: build info [Linux][clang 20.1.8][64 bit] 8bit+10bit+12bit
# kvazaar on stdout:
#   kvazaar 2.3.2 [Clang 20.1.8] 2026-10-12
assert_tool_versions() {
  banner="$("$X265" --version 2>&1 | tr -d '\r')" || fail "x265 --version failed: $banner"
  echo "$banner"
  contains "$banner" "8bit+10bit+12bit" || fail "x265 is not built for 8, 10 and 12 bits"
  ok "x265 is built for 8, 10 and 12 bits"
  if [ -n "$X265_VERSION" ]; then
    contains "$banner" "HEVC encoder version $X265_VERSION+" || fail "x265 does not report version $X265_VERSION"
    ok "x265 reports version $X265_VERSION"
  else
    echo "  X265_VERSION is not set; skipping the x265 version check"
  fi

  banner="$("$KVAZAAR" --version 2>&1 | tr -d '\r')" || fail "kvazaar --version failed: $banner"
  echo "$banner"
  if [ -n "$KVAZAAR_VERSION" ]; then
    contains "$banner" "kvazaar $KVAZAAR_VERSION [" || fail "kvazaar does not report version $KVAZAAR_VERSION"
    ok "kvazaar reports version $KVAZAAR_VERSION"
  else
    echo "  KVAZAAR_VERSION is not set; skipping the kvazaar version check"
  fi
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# plane <width> <height> <bits> <seed>: the samples of a plane, one byte each
# up to 8 bits and two bytes, little endian, above. The rows are four ramps
# that depend on the seed, repeated.
plane() {
  plane_width="$1"; plane_height="$2"; plane_bits="$3"; plane_seed="$4"
  modulus=$((1 << plane_bits))
  r=0
  while [ "$r" -lt 4 ]; do
    row=""
    x=0
    while [ "$x" -lt "$plane_width" ]; do
      value=$(((x * 37 + r * 101 + plane_seed * 59) * 13 % modulus))
      if [ "$plane_bits" -gt 8 ]; then
        printf -v octal '\\%03o\\%03o' $((value & 255)) $((value >> 8))
      else
        printf -v octal '\\%03o' "$value"
      fi
      row="$row$octal"
      x=$((x + 1))
    done
    eval "row$r=\$row"
    r=$((r + 1))
  done
  y=0
  while [ "$y" -lt "$plane_height" ]; do
    eval "row=\$row$((y % 4))"
    # shellcheck disable=SC2059
    printf "$row"
    y=$((y + 1))
  done
}

# pictures <width> <height> <bits> <400|420|422|444> <count>: planar pictures.
pictures() {
  luma_width="$1"; luma_height="$2"; sample_bits="$3"; picture_count="$5"
  case "$4" in
    400) chroma_width=0; chroma_height=0 ;;
    420) chroma_width=$((luma_width / 2)); chroma_height=$((luma_height / 2)) ;;
    422) chroma_width=$((luma_width / 2)); chroma_height="$luma_height" ;;
    444) chroma_width="$luma_width"; chroma_height="$luma_height" ;;
  esac
  picture=0
  while [ "$picture" -lt "$picture_count" ]; do
    plane "$luma_width" "$luma_height" "$sample_bits" $((picture * 3))
    if [ "$chroma_width" -gt 0 ]; then
      plane "$chroma_width" "$chroma_height" "$sample_bits" $((picture * 3 + 1))
      plane "$chroma_width" "$chroma_height" "$sample_bits" $((picture * 3 + 2))
    fi
    picture=$((picture + 1))
  done
}

# logged <label> <log file> <text>: the log of an ffmpeg run has the text.
logged() {
  contains "$(tr -d '\r' < "$2")" "$3" || { cat "$2" >&2; fail "$1: the log does not have '$3'"; }
}

# library_version <label> <log file> <version variable> <text before the version>
#
# The AVIF files of the consumers of this build are compared byte for byte, so
# the versions of the AV1 libraries are checked where the libraries report
# them: in the log of an encode or of a decode.
library_version() {
  eval "version=\${$3}"
  if [ -z "$version" ]; then
    echo "  $3 is not set; skipping the $1 version check"
    return 0
  fi
  logged "$1" "$2" "$4$version"
  ok "$1 reports version $version"
}

# lossless_hevc <name> <pixel format> <bits> <400|420|422|444>
#
# Two 16x16 pictures encoded without loss by libx265, written as a raw HEVC
# stream and decoded by the native decoder: the samples are the source ones.
# Intra pictures only (keyint=1): scripts/verify-hevc.sh has a 12-bit P picture
# that x265 4.2 does not encode without loss.
lossless_hevc() {
  name="$1"; format="$2"; bits="$3"; chroma="$4"
  pictures 16 16 "$bits" "$chroma" 2 > "$name.yuv"
  rm -f "$name.hevc" "$name.decoded.yuv"
  "$FFMPEG" -hide_banner -v info -y -f rawvideo -pix_fmt "$format" -s 16x16 -i "$name.yuv" \
    -c:v libx265 -x265-params lossless=1:keyint=1 -f hevc "$name.hevc" > "$name.log" 2>&1 \
    || { cat "$name.log" >&2; fail "$name: libx265 encode failed"; }
  [ -s "$name.hevc" ] || fail "$name: libx265 produced an empty file"
  # x265 names the library it encodes with at the end of its build info:
  # "[64 bit] 10bit", or "[64 bit][noasm] 10bit" where it has no assembly.
  logged "$name" "$name.log" "] ${bits}bit"
  "$FFMPEG" -hide_banner -v error -y -c:v hevc -i "$name.hevc" -f rawvideo -pix_fmt "$format" "$name.decoded.yuv" \
    || fail "$name: hevc decode failed"
  cmp -s "$name.yuv" "$name.decoded.yuv" || fail "$name: the decoded samples differ from the source"
  ok "$name: libx265 $format lossless -> hevc decoder gives the source samples"
}

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
  X265="../$(basename "$X265")"
  KVAZAAR="../$(basename "$KVAZAAR")"

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
  "$FFMPEG" -hide_banner -v verbose -y -i input.ppm -frames:v 1 -c:v libaom-av1 -still-picture 1 -cpu-used 8 \
    -vf "$VF" -f null - > aom.log 2>&1 || { cat aom.log >&2; fail "libaom-av1 encode failed"; }
  library_version libaom aom.log AOM_VERSION "] v"
  "$FFMPEG" -hide_banner -v verbose -y -c:v libdav1d -i out.avif -f null - > dav1d.log 2>&1 \
    || { cat dav1d.log >&2; fail "libdav1d decode failed"; }
  library_version dav1d dav1d.log DAV1D_VERSION "libdav1d "
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
  # shellcheck disable=SC2086
  "$FFMPEG" -hide_banner -v info -y $SRC -c:v libsvtav1 -crf 50 -preset 12 -vf "$VF" -f null - > svtav1.log 2>&1 \
    || { cat svtav1.log >&2; fail "libsvtav1 encode failed"; }
  library_version SVT-AV1 svtav1.log SVT_AV1_VERSION "SVT-AV1 Encoder Lib v"
  encode x264   h264.mp4  $SRC -c:v libx264 -preset ultrafast -crf 30 -vf "$VF" -f mp4
  assert_probe h264.mp4 h264
  encode x265   h265.mp4  $SRC -c:v libx265 -preset ultrafast -crf 30 -vf "$VF" -f mp4 -tag:v hvc1
  assert_probe h265.mp4 hevc

  msg "HEVC"
  lossless_hevc x265-8 yuv420p 8 420
  lossless_hevc x265-10 yuv422p10le 10 422
  lossless_hevc x265-12 yuv444p12le 12 444
  lossless_hevc x265-gray12 gray12le 12 400
  library_version x265 x265-8.log X265_VERSION "HEVC encoder version "
  logged x265-12 x265-12.log "Main 4:4:4 12 Intra profile"

  pictures 64 64 8 420 2 > kvazaar.yuv
  encode kvazaar kvazaar.hevc -f rawvideo -pix_fmt yuv420p -s 64x64 -i kvazaar.yuv -c:v libkvazaar -f hevc
  assert_probe kvazaar.hevc hevc
  encode "kvazaar decode" kvazaar.decoded.yuv -c:v hevc -i kvazaar.hevc -f rawvideo -pix_fmt yuv420p
  [ "$(($(wc -c < kvazaar.decoded.yuv)))" -eq 12288 ] || fail "the libkvazaar stream does not decode to 2 pictures"
  ok "libkvazaar yuv420p -> hevc decoder gives 2 pictures"

  # The stream of the mp4 file, back to a raw stream with its parameter sets,
  # then described and edited by the bitstream filters.
  encode "mp4 to Annex B" annexb.hevc -i h265.mp4 -c:v copy -bsf:v hevc_mp4toannexb -f hevc
  [ "$(od -An -tx1 -N 4 annexb.hevc | tr -d ' \n\r')" = "00000001" ] || fail "annexb.hevc does not start with a start code"
  "$FFMPEG" -hide_banner -v verbose -y -i annexb.hevc -c:v copy -bsf:v trace_headers -f null - > trace.log 2>&1 \
    || { cat trace.log >&2; fail "trace_headers failed"; }
  logged trace_headers trace.log "Sequence Parameter Set"
  logged trace_headers trace.log "pic_width_in_luma_samples"
  encode "filter_units" no-sei.hevc -i annexb.hevc -c:v copy -bsf:v filter_units=remove_types=39-40 -f hevc
  [ "$(($(wc -c < no-sei.hevc)))" -lt "$(($(wc -c < annexb.hevc)))" ] || fail "filter_units did not remove the SEI messages"
  encode "hevc_metadata" aud.hevc -i annexb.hevc -c:v copy -bsf:v hevc_metadata=aud=insert -f hevc
  [ "$(($(wc -c < aud.hevc)))" -gt "$(($(wc -c < annexb.hevc)))" ] || fail "hevc_metadata did not insert access unit delimiters"
  encode "edited stream decode" edited.png -i no-sei.hevc -frames:v 1 -c:v png
  ok "hevc_mp4toannexb, trace_headers, filter_units and hevc_metadata work"

  msg "x265 and kvazaar tools"
  # A picture of the x265 tool is at least one CTU, 64x64 samples by default.
  pictures 16 16 10 422 2 > x265-tool.yuv
  rm -f x265-tool.hevc
  "$X265" --input x265-tool.yuv --input-res 16x16 --input-depth 10 --input-csp i422 --fps 30 \
    --output-depth 10 --ctu 16 --lossless --keyint 1 -o x265-tool.hevc > x265-tool.log 2>&1 \
    || { cat x265-tool.log >&2; fail "x265 encode failed"; }
  encode "x265 tool decode" x265-tool.decoded.yuv -c:v hevc -i x265-tool.hevc -f rawvideo -pix_fmt yuv422p10le
  cmp -s x265-tool.yuv x265-tool.decoded.yuv || fail "x265: the decoded samples differ from the source"
  ok "x265 4:2:2 10-bit lossless -> hevc decoder gives the source samples"
  rm -f kvazaar-tool.hevc
  "$KVAZAAR" -i kvazaar.yuv --input-res 64x64 -o kvazaar-tool.hevc > kvazaar-tool.log 2>&1 \
    || { cat kvazaar-tool.log >&2; fail "kvazaar encode failed"; }
  encode "kvazaar tool decode" kvazaar-tool.decoded.yuv -c:v hevc -i kvazaar-tool.hevc -f rawvideo -pix_fmt yuv420p
  [ "$(($(wc -c < kvazaar-tool.decoded.yuv)))" -eq 12288 ] || fail "the kvazaar stream does not decode to 2 pictures"
  ok "kvazaar 4:2:0 8-bit -> hevc decoder gives 2 pictures"

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
    assert_linkage "$X265"
    assert_linkage "$KVAZAAR"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    ffmpeg_version="$("$FFMPEG" -hide_banner -version)"
    ffprobe_version="$("$FFPROBE" -hide_banner -version)"
    echo "${ffmpeg_version%%$'\n'*}"
    echo "${ffprobe_version%%$'\n'*}"
    assert_version ffmpeg "${ffmpeg_version%%$'\n'*}"
    assert_version ffprobe "${ffprobe_version%%$'\n'*}"
    assert_tool_versions
    msg "configuration"
    assert_buildconf
    assert_codecs
    assert_hevc
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
