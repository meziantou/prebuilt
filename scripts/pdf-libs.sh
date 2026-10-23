# The static libraries of the PDF tools that link libraries of their own
# (scripts/build-qpdf.sh, scripts/build-poppler.sh): one build_<library>
# function per library, each built once per prefix (.stamps).
#
# Sourced after scripts/pdf-deps.sh, as `. "$SCRIPT_DIR/pdf-libs.sh"`: a
# separate file, so that the versions of these libraries are not part of the
# build keys of the tools that do not use them (scripts/Get-BuildPlan.ps1).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

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
