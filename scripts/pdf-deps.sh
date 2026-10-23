# Shared part of the builds of the PDF tools (scripts/build-qpdf.sh, ...):
# helpers, target configuration, and the static libraries they link.
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
# Each library has its own build_<library> function, and is built once per
# prefix (.stamps). The versions come from the environment (see
# .github/workflows/ci.yml); require_versions checks the ones a build needs.
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

# Download with retries, then verify the archive really is an archive.
download() {
  url="$1"
  out="$2"
  attempt=1
  while [ "$attempt" -le 5 ]; do
    rm -f "$out"
    if curl -fsSL --retry 2 --connect-timeout 30 "$url" -o "$out"; then
      tar -tf "$out" >/dev/null 2>&1 && return 0
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
    ( cd "$SRCDIR" && tar -xf "$archive" )
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

# ---------------------------------------------------------------------------
# Libraries
# ---------------------------------------------------------------------------

# zlib, the version ffmpeg and the HarfBuzz tools are built with.
build_zlib() {
  require_versions ZLIB_VERSION
  if ! stamp_done "zlib-$ZLIB_VERSION"; then
    fetch zlib "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" \
          "zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION"
    run_cmake zlib "$SRCDIR/zlib-$ZLIB_VERSION" \
      -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_MINIZIP=OFF
    stamp_mark "zlib-$ZLIB_VERSION"
  fi

  # Targeting MinGW, zlib's CMake build installs libzs.a, but zlib.pc
  # advertises -lz.
  if [ ! -f "$PREFIX/lib/libz.a" ]; then
    for zlib_candidate in libzs.a libzlibstatic.a; do
      if [ -f "$PREFIX/lib/$zlib_candidate" ]; then
        cp "$PREFIX/lib/$zlib_candidate" "$PREFIX/lib/libz.a"
        break
      fi
    done
  fi
  [ -f "$PREFIX/lib/libz.a" ] || { echo "no static zlib in $PREFIX/lib" >&2; exit 1; }
}

# libjpeg-turbo, without its SIMD code: the C code needs no assembler, and
# decodes to the same samples on every target.
build_libjpeg_turbo() {
  require_versions LIBJPEG_TURBO_VERSION
  if ! stamp_done "libjpeg-turbo-$LIBJPEG_TURBO_VERSION"; then
    fetch libjpeg-turbo "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$LIBJPEG_TURBO_VERSION/libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz" \
          "libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz" "libjpeg-turbo-$LIBJPEG_TURBO_VERSION"
    run_cmake libjpeg-turbo "$SRCDIR/libjpeg-turbo-$LIBJPEG_TURBO_VERSION" \
      -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF \
      -DWITH_TESTS=OFF
    stamp_mark "libjpeg-turbo-$LIBJPEG_TURBO_VERSION"
  fi
  [ -f "$PREFIX/lib/libjpeg.a" ] || { echo "no static libjpeg in $PREFIX/lib" >&2; exit 1; }
}

# libpng, the version the libjxl tools are built with.
build_libpng() {
  require_versions LIBPNG_VERSION
  if ! stamp_done "libpng-$LIBPNG_VERSION"; then
    fetch libpng "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG_VERSION.tar.gz" \
          "libpng-$LIBPNG_VERSION.tar.gz" "libpng-$LIBPNG_VERSION"
    run_cmake libpng "$SRCDIR/libpng-$LIBPNG_VERSION" \
      -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
    stamp_mark "libpng-$LIBPNG_VERSION"
  fi
  [ -f "$PREFIX/lib/libpng.a" ] || { echo "no static libpng in $PREFIX/lib" >&2; exit 1; }
}

# brotli, the version ffmpeg and woff2 are built with.
build_brotli() {
  require_versions BROTLI_VERSION
  if ! stamp_done "brotli-$BROTLI_VERSION"; then
    fetch brotli "https://github.com/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz" \
          "brotli-$BROTLI_VERSION.tar.gz" "brotli-$BROTLI_VERSION"
    run_cmake brotli "$SRCDIR/brotli-$BROTLI_VERSION" -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUILD_TOOLS=OFF
    # libbrotlicommon is a private requirement of libbrotlidec and
    # libbrotlienc, which a static link needs too, whether or not the build
    # asks pkg-config for --static.
    for brotli_pc in libbrotlidec libbrotlienc; do
      sed 's/^Requires\.private:/Requires:/' "$PREFIX/lib/pkgconfig/$brotli_pc.pc" > "$PREFIX/lib/pkgconfig/$brotli_pc.pc.tmp"
      mv "$PREFIX/lib/pkgconfig/$brotli_pc.pc.tmp" "$PREFIX/lib/pkgconfig/$brotli_pc.pc"
    done
    stamp_mark "brotli-$BROTLI_VERSION"
  fi
  [ -f "$PREFIX/lib/libbrotlidec.a" ] || { echo "no static libbrotlidec in $PREFIX/lib" >&2; exit 1; }
}

# FreeType, without any optional library: the PDF tools give it the font
# programs of the files, never a compressed, PNG or WOFF2 font. HVF is the
# font format of an Apple SDK that FreeType otherwise finds on macOS.
build_freetype() {
  require_versions FREETYPE_VERSION
  freetype_tag="VER-$(echo "$FREETYPE_VERSION" | tr . -)"
  if ! stamp_done "freetype-$FREETYPE_VERSION"; then
    fetch freetype "https://github.com/freetype/freetype/archive/refs/tags/$freetype_tag.tar.gz" \
          "freetype-$FREETYPE_VERSION.tar.gz" "freetype-$freetype_tag"
    run_cmake freetype "$SRCDIR/freetype-$freetype_tag" \
      -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON \
      -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_HVF=ON
    stamp_mark "freetype-$FREETYPE_VERSION"
  fi
  [ -f "$PREFIX/lib/libfreetype.a" ] || { echo "no static FreeType in $PREFIX/lib" >&2; exit 1; }
}

# LittleCMS 2, the library only.
build_lcms2() {
  require_versions LCMS2_VERSION
  if ! stamp_done "lcms2-$LCMS2_VERSION"; then
    fetch lcms2 "https://github.com/mm2/Little-CMS/releases/download/lcms$LCMS2_VERSION/lcms2-$LCMS2_VERSION.tar.gz" \
          "lcms2-$LCMS2_VERSION.tar.gz" "lcms2-$LCMS2_VERSION"
    run_cmake lcms2 "$SRCDIR/lcms2-$LCMS2_VERSION" \
      -DLCMS2_BUILD_SHARED=OFF -DLCMS2_BUILD_STATIC=ON -DLCMS2_BUILD_TOOLS=OFF -DLCMS2_BUILD_TESTS=OFF \
      -DLCMS2_WITH_JPEG=OFF -DLCMS2_WITH_TIFF=OFF -DLCMS2_WITH_ZLIB=OFF
    stamp_mark "lcms2-$LCMS2_VERSION"
  fi
  [ -f "$PREFIX/lib/liblcms2.a" ] || { echo "no static LittleCMS 2 in $PREFIX/lib" >&2; exit 1; }
}

# The OpenJPEG library, the version the released opj_* tools are built from.
build_openjpeg_lib() {
  require_versions OPENJPEG_VERSION
  if ! stamp_done "openjpeg-$OPENJPEG_VERSION"; then
    fetch openjpeg "https://github.com/uclouvain/openjpeg/archive/refs/tags/v$OPENJPEG_VERSION.tar.gz" \
          "openjpeg-$OPENJPEG_VERSION.tar.gz" "openjpeg-$OPENJPEG_VERSION"
    run_cmake openjpeg "$SRCDIR/openjpeg-$OPENJPEG_VERSION" \
      -DBUILD_STATIC_LIBS=ON -DBUILD_CODEC=OFF -DBUILD_THIRDPARTY=OFF -DBUILD_JPIP=OFF -DBUILD_TESTING=OFF \
      -DBUILD_DOC=OFF
    stamp_mark "openjpeg-$OPENJPEG_VERSION"
  fi
  [ -f "$PREFIX/lib/libopenjp2.a" ] || { echo "no static OpenJPEG in $PREFIX/lib" >&2; exit 1; }
}

# NSS and the NSPR its source release bundles, built with NSS's own build.sh
# (gyp and ninja) as static libraries. The PKCS#11 modules NSS normally loads
# at run time (softoken, freebl) are linked in; the module of the built-in
# root certificates (nssckbi) is not, so no certificate is trusted unless it
# is in the NSS database a tool is given.
#
# nss.pc is the nss-static.pc that build.sh writes: the libraries of a static
# link, which depend on the architecture.
build_nspr_nss() {
  require_versions NSS_VERSION NSPR_VERSION
  nss_tag="NSS_$(echo "$NSS_VERSION" | tr . _)_RTM"
  nss_dir="nss-$NSS_VERSION"
  if ! stamp_done "nss-$NSS_VERSION-nspr-$NSPR_VERSION"; then
    fetch nss "https://ftp.mozilla.org/pub/security/nss/releases/$nss_tag/src/nss-$NSS_VERSION-with-nspr-$NSPR_VERSION.tar.gz" \
          "nss-$NSS_VERSION-with-nspr-$NSPR_VERSION.tar.gz" "$nss_dir"
    msg "building NSS $NSS_VERSION and NSPR $NSPR_VERSION"
    # use_system_sqlite=0 and use_system_zlib=0: the copies of SQLite (for
    # its databases) and zlib in NSS, on every target; NSS uses the system ones
    # on macOS and Linux by default.
    nss_args="--opt --static --disable-tests -Ddisable_werror=1 -Duse_system_sqlite=0 -Duse_system_zlib=0"
    # NO_DLOPEN_NULL: NSPR opens the executable with dlopen(NULL) when it
    # starts, and aborts when that fails, as it does in a static musl binary.
    nss_cflags="${CFLAGS:-}"
    case "$TARGET" in
      linux-*) nss_cflags="$nss_cflags -DNO_DLOPEN_NULL" ;;
    esac
    # shellcheck disable=SC2086
    ( cd "$SRCDIR/$nss_dir/nss" && CFLAGS="$nss_cflags" CCC="${CXX:-c++}" ./build.sh $nss_args )
    nss_dist="$SRCDIR/$nss_dir/dist"
    nss_pc="$nss_dist/Release/lib/pkgconfig/nss-static.pc"
    [ -f "$nss_pc" ] || { echo "NSS wrote no nss-static.pc" >&2; exit 1; }

    mkdir -p "$PREFIX/include/nss" "$PREFIX/include/nspr" "$PREFIX/lib/pkgconfig"
    cp -R "$nss_dist/public/nss/." "$PREFIX/include/nss/"
    cp -R "$nss_dist/Release/include/nspr/." "$PREFIX/include/nspr/"
    cp "$nss_dist"/Release/lib/*.a "$PREFIX/lib/"

    nspr_libs="-lplds4 -lplc4 -lnspr4"
    case "$TARGET" in
      linux-*) nspr_libs="$nspr_libs -lpthread -ldl" ;;
    esac
    nss_libs="$(sed -n 's/^Libs: -L${libdir} //p' "$nss_pc")"
    [ -n "$nss_libs" ] || { echo "no libraries in $nss_pc" >&2; exit 1; }

    # The static libraries of NSS reference each other in both directions,
    # which the linker of macOS resolves in any order, and GNU ld, which reads
    # each archive once, does not. One archive with all of them is searched
    # until nothing more resolves.
    case "$TARGET" in
      linux-*)
        {
          echo "CREATE $PREFIX/lib/libnss_all.a"
          for nss_lib in $nss_libs; do
            echo "ADDLIB $PREFIX/lib/lib${nss_lib#-l}.a"
          done
          echo "SAVE"
          echo "END"
        } > "$WORKDIR/build-$TOOL_ID-nss_all.mri"
        ar -M < "$WORKDIR/build-$TOOL_ID-nss_all.mri"
        ranlib "$PREFIX/lib/libnss_all.a"
        nss_libs="-lnss_all"
        ;;
    esac
    cat > "$PREFIX/lib/pkgconfig/nspr.pc" <<PC
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include/nspr

Name: NSPR
Description: The Netscape Portable Runtime (static)
Version: $NSPR_VERSION
Libs: -L\${libdir} $nspr_libs
Cflags: -I\${includedir}
PC
    cat > "$PREFIX/lib/pkgconfig/nss.pc" <<PC
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include/nss

Name: NSS
Description: Network Security Services (static)
Version: $NSS_VERSION
Requires: nspr >= $NSPR_VERSION
Libs: -L\${libdir} $nss_libs
Cflags: -I\${includedir} -DNSS_USE_STATIC_LIBS
PC
    purge_shared_libs
    stamp_mark "nss-$NSS_VERSION-nspr-$NSPR_VERSION"
  fi
  [ -f "$PREFIX/lib/libnss_static.a" ] || { echo "no static NSS in $PREFIX/lib" >&2; exit 1; }
}
