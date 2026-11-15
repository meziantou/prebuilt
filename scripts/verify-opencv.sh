#!/usr/bin/env bash
#
# Verifies opencv-oracle, built by scripts/build-opencv.sh.
#
#   bash scripts/verify-opencv.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage and version assertions only
#   run   version assertion plus the tests below (must run on the target)
#   all   both (default)
#
# The tests run each command on 64 x 64 images of raw samples written byte by
# byte, and check what OpenCV finds:
# - hough-lines (cv::HoughLines) and hough-lines-p (cv::HoughLinesP): a
#   vertical line at x = 20 and a horizontal line at y = 40;
# - harris (cv::cornerHarris, and its response as raw floats) and
#   good-features (cv::goodFeaturesToTrack, Harris and minimum eigenvalue): the
#   4 corners of a white square;
# - fast (cv::FAST, 9_16 and 7_12, with non-maximum suppression): 3 isolated
#   dots (the corners of a binary square have equal scores, which the
#   suppression removes);
# - homography (cv::findHomography): x' = 2 x + 10, y' = 2 y + 20, from 8
#   exact correspondences with the DLT (method 0), and from these and 2
#   outliers with RANSAC and a fixed seed, which finds the 8 inliers;
# - inpaint (cv::inpaint, Telea and Navier-Stokes): a hole in a constant image
#   is filled with values close to it, and the rest of the image is kept;
#   PNG output, read again as input.
# Integer results are compared exactly, floats within 1e-6.
#
# OPENCV_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
[ -n "$OPENCV_VERSION" ] || { echo "OPENCV_VERSION is not set" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

BIN="./opencv-oracle-$TARGET$EXE"
[ -f "$BIN" ] || { echo "missing $BIN" >&2; exit 1; }
chmod +x "$BIN" 2>/dev/null || true

export LC_ALL=C
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

msg()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m %s\n' "$*"; }

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# shellcheck source=verify-common.sh
. "$SCRIPT_DIR/verify-common.sh"

# image <file> <awk condition on x and y> [value inside] [value outside]: 64 x 64
# raw samples.
image() {
  awk -v inside="${3:-255}" -v outside="${4:-0}" "BEGIN { for (y = 0; y < 64; y++) for (x = 0; x < 64; x++) printf \"%c\", ($2) ? inside : outside }" > "$1"
  [ "$(file_size "$1")" = 4096 ] || fail "$1 has $(file_size "$1") bytes"
}

# numbers_close <label> <actual numbers> <expected numbers>: the same count of
# numbers, each within 1e-6.
numbers_close() {
  printf '%s\n%s\n' "$2" "$3" | tr -c '0-9eE.+\n-' ' ' | awk -v label="$1" '
    NR == 1 { n = split($0, a, " ") }
    NR == 2 {
      m = split($0, b, " ")
      if (n != m) { print label ": " n " numbers, expected " m > "/dev/stderr"; exit 1 }
      for (i = 1; i <= n; i++) {
        d = a[i] - b[i]; if (d < 0) d = -d
        if (d > 1e-6) { print label ": " a[i] " is not " b[i] > "/dev/stderr"; exit 1 }
      }
    }' || fail "$1:
  actual:   $2
  expected: $3"
  ok "$1"
}

oracle() {
  "$O" "$@" 2> oracle.err | tr -d '\r' || { cat oracle.err >&2; fail "opencv-oracle $* failed"; }
}

tests() {
  workdir="smoke-opencv-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  O="../opencv-oracle-$TARGET$EXE"

  image lines.raw 'x == 20 || y == 40'
  image square.raw 'x >= 16 && x < 48 && y >= 16 && y < 48'
  image dots.raw '(x == 20 && y == 20) || (x == 40 && y == 30) || (x == 30 && y == 45)' 200 0
  image gray.raw '1' 100 100
  image mask.raw 'x >= 28 && x < 36 && y >= 28 && y < 36'

  msg "Hough lines"
  expect "hough-lines: (rho, theta, votes) of 2 lines" "$(oracle hough-lines raw:64:64:1:lines.raw 1 0.0174532925 40)" \
    '{"lines": [[20, 0, 64], [40, 1.57079637, 64]]}'
  expect "hough-lines-p: the 2 segments" "$(oracle hough-lines-p raw:64:64:1:lines.raw 1 0.0174532925 30 20 2)" \
    '{"lines": [[0, 40, 63, 40], [20, 63, 20, 0]]}'

  msg "corners"
  harris="$(oracle harris raw:64:64:1:square.raw 3 3 0.04 response.raw)"
  contains "$harris" '"width": 64, "height": 64,' || fail "harris: $harris"
  contains "$harris" '"maxLocation": [16, 16]}' || fail "harris: $harris"
  ok "harris: the maximum of the response is the corner (16, 16): $harris"
  expect "harris: the response, 64 x 64 floats" "$(file_size response.raw)" "16384"
  expect "good-features (Harris): the 4 corners" "$(oracle good-features raw:64:64:1:square.raw 4 0.1 10 3 1 0.04)" \
    '{"corners": [[47, 47], [16, 47], [47, 16], [16, 16]]}'
  expect "good-features (minimum eigenvalue): the 4 corners" "$(oracle good-features raw:64:64:1:square.raw 4 0.1 10 3 0 0.04)" \
    '{"corners": [[47, 47], [16, 47], [47, 16], [16, 16]]}'
  expect "fast 9_16: the 3 dots" "$(oracle fast raw:64:64:1:dots.raw 20 1 9_16)" "$PIN_FAST_9_16"
  expect "fast 7_12, 3 corners of the square" "$(oracle fast raw:64:64:1:square.raw 10 1 7_12)" \
    '{"keypoints": [[16, 16, 254], [47, 16, 254], [16, 47, 254]]}'

  msg "homography"
  : > exact.txt
  for p in "0 0" "10 0" "0 10" "10 10" "5 3" "7 9" "2 8" "9 1"; do
    set -- $p
    echo "$1 $2 $((2 * $1 + 10)) $((2 * $2 + 20))" >> exact.txt
  done
  { cat exact.txt; echo "3 3 90 -40"; echo "6 2 -30 70"; } > outliers.txt
  dlt="$(oracle homography exact.txt dlt 3 0)"
  numbers_close "DLT (method 0): x' = 2 x + 10, y' = 2 y + 20" "$(echo "$dlt" | sed 's/.*"homography": \[\([^]]*\)\].*/\1/')" "2 0 10 0 2 20 0 0 1"
  ransac="$(oracle homography outliers.txt ransac 3 1)"
  numbers_close "RANSAC with 2 outliers: the homography" "$(echo "$ransac" | sed 's/.*"homography": \[\([^]]*\)\].*/\1/')" "2 0 10 0 2 20 0 0 1"
  contains "$ransac" '"inliers": [1, 1, 1, 1, 1, 1, 1, 1, 0, 0]}' || fail "RANSAC: $ransac"
  ok "RANSAC: the 8 inliers and the 2 outliers"

  msg "inpaint"
  for method in telea ns; do
    expect "inpaint $method" "$(oracle inpaint raw:64:64:1:gray.raw raw:64:64:1:mask.raw 3 "$method" "raw:$method.raw")" \
      '{"width": 64, "height": 64, "channels": 1}'
    od -An -v -tu1 "$method.raw" | tr -s ' \n\r' '\n\n\n' | awk -v method="$method" '
      NF { i = n++; x = i % 64; y = int(i / 64)
           hole = x >= 28 && x < 36 && y >= 28 && y < 36
           if (!hole && $1 != 100) { print method ": (" x ", " y ") is " $1 > "/dev/stderr"; exit 1 }
           if (hole && ($1 < 95 || $1 > 105)) { print method ": the hole has " $1 > "/dev/stderr"; exit 1 } }
      END { if (n != 4096) { print method ": " n " samples" > "/dev/stderr"; exit 1 } }' \
      || fail "inpaint $method: the samples"
    ok "inpaint $method: the hole is filled with 95 to 105, the rest is kept"
  done
  expect "inpaint to a PNG file" "$(oracle inpaint raw:64:64:1:gray.raw raw:64:64:1:mask.raw 3 telea telea.png)" \
    '{"width": 64, "height": 64, "channels": 1}'
  expect "a PNG file: the signature" "$(hex_of_n telea.png 8)" "89504e470d0a1a0a"
  contains "$(oracle harris telea.png 3 3 0.04)" '"width": 64, "height": 64,' || fail "opencv-oracle does not read the PNG file"
  ok "opencv-oracle reads the PNG file"

  cd ..
  ok "all tests passed"
}

PIN_FAST_9_16='{"keypoints": [[20, 20, 199], [40, 30, 199], [30, 45, 199]]}'

case "$MODE" in
  link|all)
    msg "linkage and version ($TARGET)"
    assert_linkage "$BIN"
    grep -a -q -F "$OPENCV_VERSION" "$BIN" || fail "$BIN does not contain '$OPENCV_VERSION'"
    ok "$BIN contains $OPENCV_VERSION"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    expect "opencv-oracle --version" "$("$BIN" --version | tr -d '\r')" "opencv-oracle (OpenCV $OPENCV_VERSION)"
    tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
