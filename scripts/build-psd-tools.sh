#!/usr/bin/env bash
#
# Builds the psd-tools bundle: psd-tools, a reader and writer of PSD and PSB
# files that shares no code with ImageMagick, with a Python runtime, so that no
# Python needs to be installed:
#
#   psd-tools-<target>.tar.gz
#     psd-tools          (POSIX shell launcher; psd-tools.exe on Windows)
#     lib/psd-tools-cli.py
#     lib/wheels.txt     (the wheels of python/, with their SHA-256)
#     python/            (python-build-standalone, with the wheels in its
#                         site-packages)
#
#   bash scripts/build-psd-tools.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# psd-tools (https://github.com/psd-tools/psd-tools) is a Python library, with
# no command-line tool for its samples: scripts/psd-tools-cli.py is one, which
# dumps the samples of a file as raw files and a JSON description, and writes a
# file from them, with the low-level API of psd-tools.
#
# The Python runtime is the "install_only_stripped" build of
# python-build-standalone (https://github.com/astral-sh/python-build-standalone)
# for the target, checked against the SHA256SUMS of its release. The wheels are
# pinned versions of psd-tools and its dependencies (numpy, Pillow, attrs),
# downloaded from PyPI and checked against the SHA-256 PyPI publishes
# (scripts/psd-tools-wheels.py): no pip and no resolver are involved, and PyPI
# never changes the file of a version. The Linux runtimes are the glibc builds,
# with the manylinux wheels: the bundle needs glibc 2.28 or later, as the numpy
# and Pillow wheels do; there are no wheels of numpy for musl that the Python
# of python-build-standalone loads.
#
# Nothing is compiled but the Windows launcher, scripts/psd-tools-launcher.c,
# cross-compiled with llvm-mingw (point LLVM_MINGW_ROOT at the extracted
# toolchain), so every target can be built on Linux or macOS. The Python of the
# build machine (python3) runs scripts/psd-tools-wheels.py.
#
# PSD_TOOLS_VERSION, PSD_TOOLS_PYTHON_VERSION, PYTHON_BUILD_STANDALONE_RELEASE,
# NUMPY_VERSION, PILLOW_VERSION and ATTRS_VERSION come from the environment
# (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
for name in PSD_TOOLS_VERSION PSD_TOOLS_PYTHON_VERSION PYTHON_BUILD_STANDALONE_RELEASE NUMPY_VERSION PILLOW_VERSION ATTRS_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
SRCDIR="$WORKDIR/psd-tools-src"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$SRCDIR"

msg() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

download() {
  url="$1"; out="$2"
  attempt=1
  while [ "$attempt" -le 5 ]; do
    rm -f "$out"
    if curl -fsSL --retry 2 --connect-timeout 30 "$url" -o "$out"; then
      return 0
    fi
    echo "download attempt $attempt failed: $url" >&2
    attempt=$((attempt + 1))
    sleep $((2 * attempt))
  done
  echo "failed to download $url after 5 attempts" >&2
  return 1
}

HOST_PYTHON=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null; then
    HOST_PYTHON="$candidate"
    break
  fi
done
[ -n "$HOST_PYTHON" ] || { echo "a Python 3.8 or later (python3) is needed to install the wheels" >&2; exit 2; }

case "$TARGET" in
  linux-x64)   TRIPLE="x86_64-unknown-linux-gnu" ;;
  linux-arm64) TRIPLE="aarch64-unknown-linux-gnu" ;;
  win-x64)     TRIPLE="x86_64-pc-windows-msvc" ;;
  osx-arm64)   TRIPLE="aarch64-apple-darwin" ;;
esac

# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------

PBS_NAME="cpython-$PSD_TOOLS_PYTHON_VERSION+$PYTHON_BUILD_STANDALONE_RELEASE-$TRIPLE-install_only_stripped.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_BUILD_STANDALONE_RELEASE"
if [ ! -f "$SRCDIR/$PBS_NAME" ]; then
  msg "fetching Python $PSD_TOOLS_PYTHON_VERSION ($TRIPLE)"
  download "$PBS_URL/$PBS_NAME" "$SRCDIR/$PBS_NAME.tmp"
  download "$PBS_URL/SHA256SUMS" "$SRCDIR/SHA256SUMS-$PYTHON_BUILD_STANDALONE_RELEASE"
  expected="$(awk -v name="$PBS_NAME" '$2 == name { print $1 }' "$SRCDIR/SHA256SUMS-$PYTHON_BUILD_STANDALONE_RELEASE")"
  [ -n "$expected" ] || { echo "$PBS_NAME is not in the SHA256SUMS of $PYTHON_BUILD_STANDALONE_RELEASE" >&2; exit 1; }
  actual="$(sha256_of "$SRCDIR/$PBS_NAME.tmp")"
  [ "$expected" = "$actual" ] || { echo "the SHA-256 of $PBS_NAME is $actual, expected $expected" >&2; exit 1; }
  mv "$SRCDIR/$PBS_NAME.tmp" "$SRCDIR/$PBS_NAME"
fi

BUNDLE="$WORKDIR/psd-tools-bundle-$TARGET"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/lib"
tar -xzf "$SRCDIR/$PBS_NAME" -C "$BUNDLE"
[ -d "$BUNDLE/python" ] || { echo "$PBS_NAME has no python/ folder" >&2; exit 1; }

PY_MINOR="$(echo "$PSD_TOOLS_PYTHON_VERSION" | cut -d . -f 1-2)"
if [ "$TARGET" = win-x64 ]; then
  STDLIB="$BUNDLE/python/Lib"
  [ -f "$BUNDLE/python/python.exe" ] || { echo "the runtime has no python.exe" >&2; exit 1; }
else
  STDLIB="$BUNDLE/python/lib/python$PY_MINOR"
  [ -x "$BUNDLE/python/bin/python3" ] || { echo "the runtime has no bin/python3" >&2; exit 1; }
fi
SITE_PACKAGES="$STDLIB/site-packages"
[ -d "$SITE_PACKAGES" ] || { echo "the runtime has no $SITE_PACKAGES" >&2; exit 1; }

# What the tool does not use: the test suite, Tcl/Tk (tkinter, IDLE, turtle),
# ensurepip and pip, and the headers and import libraries of the C API.
msg "trimming the runtime"
rm -rf "$STDLIB/test" "$STDLIB/idlelib" "$STDLIB/tkinter" "$STDLIB/turtledemo" "$STDLIB/turtle.py" \
       "$STDLIB/ensurepip" "$SITE_PACKAGES"/pip "$SITE_PACKAGES"/pip-*.dist-info \
       "$BUNDLE/python/include" "$BUNDLE/python/share" "$BUNDLE/python/libs" "$BUNDLE/python/tcl" \
       "$BUNDLE/python/Scripts" "$BUNDLE/python/bin/pip"* "$BUNDLE/python/bin/idle"* "$BUNDLE/python/bin/pydoc"* \
       "$BUNDLE/python/bin/python$PY_MINOR-config" "$BUNDLE/python/bin/python3-config" \
       "$BUNDLE/python/lib/pkgconfig" "$BUNDLE/python/lib/tcl"* "$BUNDLE/python/lib/tk"* "$BUNDLE/python/lib/itcl"* \
       "$BUNDLE/python/lib/libtcl"* "$BUNDLE/python/lib/libtk"* \
       "$BUNDLE/python/lib/thread"* "$STDLIB/config-$PY_MINOR"*
rm -f "$STDLIB"/lib-dynload/_tkinter* "$BUNDLE"/python/DLLs/_tkinter* "$BUNDLE"/python/DLLs/tcl*.dll \
      "$BUNDLE"/python/DLLs/tk*.dll

# ---------------------------------------------------------------------------
# Wheels
# ---------------------------------------------------------------------------

msg "installing psd-tools $PSD_TOOLS_VERSION"
# shellcheck disable=SC2086
"$HOST_PYTHON" -I "$SCRIPT_DIR/psd-tools-wheels.py" "$TARGET" "$PSD_TOOLS_PYTHON_VERSION" "$SITE_PACKAGES" \
  "$SRCDIR/wheels-$TARGET.txt" \
  "psd-tools==$PSD_TOOLS_VERSION" "numpy==$NUMPY_VERSION" "pillow==$PILLOW_VERSION" "attrs==$ATTRS_VERSION"
cp "$SRCDIR/wheels-$TARGET.txt" "$BUNDLE/lib/wheels.txt"
# The test suites of the wheels. The launchers run Python with -B, so that
# nothing is written to the bundle: the wheels are compiled at every run, and
# the standard library comes with its .pyc files.
find "$SITE_PACKAGES/numpy" -type d -name tests -prune -exec rm -rf {} +

# psd-tools must be the version it says, and its dependencies the ones of the
# command line: psd-tools 1.26 needs attrs, Pillow and numpy only.
# The METADATA of some wheels has CRLF line ends.
METADATA="$SITE_PACKAGES/psd_tools-$PSD_TOOLS_VERSION.dist-info/METADATA"
installed="$(tr -d '\r' < "$METADATA" 2>/dev/null | sed -n 's/^Version: //p' || true)"
[ "$installed" = "$PSD_TOOLS_VERSION" ] || { echo "psd-tools $PSD_TOOLS_VERSION is not installed (got '$installed')" >&2; exit 1; }
requires="$(tr -d '\r' < "$METADATA" | sed -n 's/^Requires-Dist: \([A-Za-z0-9_.-]*\).*/\1/p' \
            | grep -v -i -E '^(aggdraw|scipy)$' | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ')"
[ "$requires" = "attrs numpy pillow " ] || { echo "psd-tools $PSD_TOOLS_VERSION requires: $requires" >&2; exit 1; }

cp "$SCRIPT_DIR/psd-tools-cli.py" "$BUNDLE/lib/psd-tools-cli.py"

# ---------------------------------------------------------------------------
# Launcher
# ---------------------------------------------------------------------------

case "$TARGET" in
  win-x64)
    [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
    export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
    msg "building psd-tools.exe"
    x86_64-w64-mingw32-clang -municode -O2 -static -Wall -Werror -o "$BUNDLE/psd-tools.exe" "$SCRIPT_DIR/psd-tools-launcher.c"
    x86_64-w64-mingw32-strip "$BUNDLE/psd-tools.exe"
    LAUNCHER="psd-tools.exe"
    ;;
  *)
    cat > "$BUNDLE/psd-tools" <<'SH'
#!/bin/sh
# psd-tools, with the Python of this bundle: isolated from the environment (-I:
# no PYTHONPATH, no user site-packages), without writing .pyc files (-B).
bundle="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$bundle/python/bin/python3" -I -B "$bundle/lib/psd-tools-cli.py" "$@"
SH
    chmod 755 "$BUNDLE/psd-tools"
    LAUNCHER="psd-tools"
    ;;
esac

out="$WORKDIR/psd-tools-$TARGET.tar.gz"
rm -f "$out"
# COPYFILE_DISABLE: the tar of macOS adds ._ files with the extended
# attributes otherwise.
( cd "$BUNDLE" && COPYFILE_DISABLE=1 tar -czf "$out" "$LAUNCHER" lib python )

du -sh "$BUNDLE/python"
ls -lh "$out"
msg "built the psd-tools bundle for $TARGET"
