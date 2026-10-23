#!/usr/bin/env bash
#
# Builds pdfium_test, the command-line tool of PDFium, with the GN/depot_tools
# build of PDFium itself, and bundles it with the fonts of the PDFium pixel
# tests:
#
#   pdfium_test-<target>.tar.gz
#     pdfium_test[.exe]
#     fonts/            (testing/resources/fonts: ahem, symbolneu, ...)
#     test_fonts/       (third_party/test_fonts)
#     LICENSE
#
#   bash scripts/build-pdfium.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# PDFium has no releases: it is built from a chromium/<N> branch, the ones
# bblanchon/pdfium-binaries publishes. It is configured as the PDFium pixel
# tests are run: AGG renderer (no Skia), no V8 and XFA, so the rasters of
# pdfium_test --png can be compared with the PDFium expectations
# (testing/resources/pixel/*_expected.pdf.*.png). The test runner
# (testing/tools/test_runner.py) runs:
#
#   pdfium_test --send-events --png --md5 --time=1399672130
#               --font-dir=<bundle>/test_fonts --croscore-font-names <file>.pdf
#
# (--font-dir=<bundle>/fonts/ahem or fonts/symbolneu for the tests whose
# folder names say use_ahem or use_symbolneu.)
#
# The build uses the toolchain Chromium downloads: its clang and its libc++,
# linked statically. Its Linux binaries are linked against the glibc of the
# Debian sysroot of Chromium, dynamically: they do not run on musl. Chromium
# ships its clang for x64 Linux machines only, so linux-arm64 is
# cross-compiled there. win-x64 is built on Windows with Visual Studio and
# the Windows SDK (clang-cl and the static CRT); osx-arm64 on macOS with
# Xcode.
#
# PDFIUM_VERSION (the N of chromium/<N>) and DEPOT_TOOLS_COMMIT come from the
# environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
for name in PDFIUM_VERSION DEPOT_TOOLS_COMMIT; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
DEPOT_TOOLS="$WORKDIR/pdfium-depot-tools"
CHECKOUT="$WORKDIR/pdfium-checkout"
SOURCE="$CHECKOUT/pdfium"
OUT="$SOURCE/out/prebuilt-$TARGET"

msg() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

EXE=""
case "$TARGET" in
  linux-x64) GN_OS=linux; GN_CPU=x64 ;;
  linux-arm64) GN_OS=linux; GN_CPU=arm64 ;;
  win-x64) GN_OS=win; GN_CPU=x64; EXE=".exe" ;;
  osx-arm64) GN_OS=mac; GN_CPU=arm64 ;;
esac

# ---------------------------------------------------------------------------
# depot_tools, at a fixed commit: it updates itself unless told not to.
# ---------------------------------------------------------------------------

export DEPOT_TOOLS_UPDATE=0
# Windows: the Visual Studio of the machine, not Google's internal toolchain.
export DEPOT_TOOLS_WIN_TOOLCHAIN=0
if [ ! -d "$DEPOT_TOOLS/.git" ]; then
  msg "fetching depot_tools $DEPOT_TOOLS_COMMIT"
  rm -rf "$DEPOT_TOOLS"
  git init -q "$DEPOT_TOOLS"
  git -C "$DEPOT_TOOLS" fetch -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_COMMIT"
  git -C "$DEPOT_TOOLS" checkout -q FETCH_HEAD
fi
export PATH="$DEPOT_TOOLS:$PATH"
# What update_depot_tools does but the update: the Python and CIPD tools the
# wrappers (gn, ninja, ...) run with. On Windows, the batch script does it:
# ensure_bootstrap does not install the Python of the .bat wrappers there.
if [ "$TARGET" = "win-x64" ]; then
  MSYS2_ARG_CONV_EXCL='*' cmd.exe /c "$(cygpath -w "$DEPOT_TOOLS/bootstrap/win_tools.bat")"
  [ -f "$DEPOT_TOOLS/python3_bin_reldir.txt" ] || { echo "depot_tools is not bootstrapped: no python3_bin_reldir.txt" >&2; exit 1; }
else
  "$DEPOT_TOOLS/ensure_bootstrap"
fi

# ---------------------------------------------------------------------------
# PDFium
# ---------------------------------------------------------------------------

# checkout_configuration=minimal: no Skia and no V8, which this build does
# not use. The test fonts are fetched whatever the configuration.
mkdir -p "$CHECKOUT"
cd "$CHECKOUT"
if [ ! -f .gclient ]; then
  gclient config --unmanaged https://pdfium.googlesource.com/pdfium.git --custom-var checkout_configuration=minimal
  echo "target_os = [ '$GN_OS' ]" >> .gclient
fi
msg "syncing PDFium chromium/$PDFIUM_VERSION"
gclient sync -r "origin/chromium/$PDFIUM_VERSION" --no-history --shallow
[ -f "$SOURCE/testing/resources/fonts/ahem/Ahem.ttf" ] || { echo "the checkout has no testing/resources/fonts" >&2; exit 1; }
[ -d "$SOURCE/third_party/test_fonts/test_fonts" ] || { echo "the checkout has no third_party/test_fonts" >&2; exit 1; }

if [ "$TARGET" = "linux-arm64" ]; then
  msg "installing the arm64 Debian sysroot"
  python3 "$SOURCE/build/linux/sysroot_scripts/install-sysroot.py" --arch=arm64
fi

msg "configuring pdfium_test for $TARGET"
mkdir -p "$OUT"
cat > "$OUT/args.gn" <<GN
is_debug = false
is_component_build = false
symbol_level = 0
pdf_is_standalone = true
pdf_use_skia = false
pdf_enable_v8 = false
pdf_enable_xfa = false
pdf_use_partition_alloc = false
use_custom_libcxx = true
treat_warnings_as_errors = false
clang_use_chrome_plugins = false
target_os = "$GN_OS"
target_cpu = "$GN_CPU"
GN
( cd "$SOURCE" && gn gen "out/prebuilt-$TARGET" )

msg "building pdfium_test"
ninja -C "$OUT" pdfium_test
[ -f "$OUT/pdfium_test$EXE" ] || { echo "pdfium_test$EXE was not built in $OUT" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Bundle
# ---------------------------------------------------------------------------

BUNDLE="$WORKDIR/pdfium-bundle-$TARGET"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/fonts" "$BUNDLE/test_fonts"
cp "$OUT/pdfium_test$EXE" "$BUNDLE/pdfium_test$EXE"
case "$TARGET" in
  win-x64) ;;
  osx-arm64) strip -x "$BUNDLE/pdfium_test" ;;
  *) "$SOURCE/third_party/llvm-build/Release+Asserts/bin/llvm-strip" "$BUNDLE/pdfium_test" ;;
esac
chmod 755 "$BUNDLE/pdfium_test$EXE"
cp -R "$SOURCE/testing/resources/fonts/." "$BUNDLE/fonts/"
# The fonts the hook extracted, without the archive and the git files.
cp -R "$SOURCE/third_party/test_fonts/test_fonts/." "$BUNDLE/test_fonts/"
cp "$SOURCE/LICENSE" "$BUNDLE/LICENSE"

out="$WORKDIR/pdfium_test-$TARGET.tar.gz"
rm -f "$out"
# COPYFILE_DISABLE: the tar of macOS adds ._ files with the extended
# attributes otherwise.
( cd "$BUNDLE" && COPYFILE_DISABLE=1 tar -czf "$out" "pdfium_test$EXE" fonts test_fonts LICENSE )

ls -lh "$BUNDLE/pdfium_test$EXE" "$out"
msg "built pdfium_test for $TARGET"
