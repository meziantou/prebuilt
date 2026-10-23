# Shared part of the builds of the PDF tools (scripts/build-qpdf.sh, ...):
# helpers and target configuration. The static libraries some of them link
# are built by scripts/pdf-libs.sh.
#
# Sourced, not run, after the caller has set:
#   TARGET      linux-x64 | linux-arm64 | win-x64 | osx-arm64
#   TOOL_ID     short name of the build: the prefix is $TOOL_ID-deps, the build
#               directories build-$TOOL_ID-<library>, the sources $TOOL_ID-src
#   SCRIPT_DIR  the scripts directory
#
# Callers source it as `. "$SCRIPT_DIR/pdf-deps.sh"`, so that it is part of
# their build key (scripts/Get-BuildPlan.ps1).
#
# The versions come from the environment (see .github/workflows/ci.yml);
# require_versions checks the ones a build needs.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

WORKDIR="$(pwd)"
PREFIX="$WORKDIR/$TOOL_ID-deps"
SRCDIR="$WORKDIR/$TOOL_ID-src"
STAMPDIR="$PREFIX/.stamps"

mkdir -p "$PREFIX" "$SRCDIR" "$STAMPDIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

msg() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# require_versions NAME...: fails when one of the variables is empty.
require_versions() {
  for name in "$@"; do
    eval "value=\${$name}"
    [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
  done
}

job_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.logicalcpu
  else
    echo 2
  fi
}
JOBS="$(job_count)"

# list_archive <file>: lists a .zip file with unzip (GNU tar does not read
# them), and any other archive with tar.
list_archive() {
  case "$1" in
    *.zip) unzip -l "$1" ;;
    *) tar -tf "$1" ;;
  esac
}

# Download with retries, then verify the archive really is an archive.
download() {
  url="$1"
  out="$2"
  attempt=1
  while [ "$attempt" -le 5 ]; do
    rm -f "$out"
    if curl -fsSL --retry 2 --connect-timeout 30 "$url" -o "$out"; then
      list_archive "$out" >/dev/null 2>&1 && return 0
      echo "downloaded file is not a valid archive: $url" >&2
    fi
    echo "download attempt $attempt failed: $url" >&2
    attempt=$((attempt + 1))
    sleep $((2 * attempt))
  done
  echo "failed to download $url after 5 attempts" >&2
  return 1
}

# fetch <name> <url> <archive> <directory>: downloads and extracts into $SRCDIR.
fetch() {
  name="$1"; url="$2"; archive="$3"; dir="$4"
  if [ ! -d "$SRCDIR/$dir" ]; then
    msg "fetching $name"
    download "$url" "$SRCDIR/$archive"
    case "$archive" in
      *.zip) ( cd "$SRCDIR" && unzip -q "$archive" ) ;;
      *) ( cd "$SRCDIR" && tar -xf "$archive" ) ;;
    esac
  fi
  [ -d "$SRCDIR/$dir" ] || { echo "expected source directory $dir not found" >&2; exit 1; }
}

stamp_done() { [ -f "$STAMPDIR/$1" ]; }
stamp_mark() { : > "$STAMPDIR/$1"; }

# Full-static builds must never see a shared library. Delete any that a
# dependency installs despite being asked for static-only.
purge_shared_libs() {
  rm -f "$PREFIX"/lib/*.so "$PREFIX"/lib/*.so.* "$PREFIX"/lib/*.dylib \
        "$PREFIX"/lib/*.dll.a "$PREFIX"/bin/*.dll 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Target configuration
# ---------------------------------------------------------------------------

EXE=""
CMAKE_CROSS_ARGS=""
STRIP="strip"

case "$TARGET" in
  linux-*)
    # Same compiler as the ffmpeg build.
    export CC=clang CXX=clang++
    EXE_LDFLAGS="-static"
    ;;
  win-x64)
    EXE=".exe"
    [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
    export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
    MINGW_TRIPLE="x86_64-w64-mingw32"
    export MINGW_TRIPLE
    CMAKE_CROSS_ARGS="-DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/mingw-toolchain.cmake -DMINGW_TRIPLE=$MINGW_TRIPLE"
    # Links libc++, libunwind and winpthreads statically.
    EXE_LDFLAGS="-static"
    STRIP="$MINGW_TRIPLE-strip"
    ;;
  osx-arm64)
    # macOS has no static libSystem: the goal here is "no non-system dylibs".
    EXE_LDFLAGS=""
    STRIP="strip -x"
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    ;;
  *)
    echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

# pkg-config must see the prefix and nothing else, so that Homebrew cannot leak
# a .dylib into the link.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

CMAKE_COMMON="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=OFF"

# run_cmake <name> <source dir> [extra cmake args...]
run_cmake() {
  name="$1"; src="$2"; shift 2
  msg "building $name"
  # shellcheck disable=SC2086
  cmake -S "$src" -B "$WORKDIR/build-$TOOL_ID-$name" $CMAKE_COMMON $CMAKE_CROSS_ARGS "$@"
  cmake --build "$WORKDIR/build-$TOOL_ID-$name" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-$TOOL_ID-$name"
  purge_shared_libs
}

# finish_outputs <file>...: strips the outputs and makes them executable.
finish_outputs() {
  msg "stripping"
  # shellcheck disable=SC2086
  $STRIP "$@"
  chmod +x "$@"
  ls -lh "$@"
}
