#!/usr/bin/env bash
#
# Builds a statically linked TestGrammar, the proof-of-concept checker of the
# Arlington PDF Model (pdf-association/arlington-pdf-model), and bundles it
# with the TSV files of the model:
#
#   TestGrammar-<target>.tar.gz
#     TestGrammar[.exe]
#     tsv/<1.0 ... 2.0, latest>/*.tsv
#     LICENSE
#
#   bash scripts/build-arlington.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# The repository has no recent release: it is built from a commit of its
# master branch. TestGrammar and the TSV files of the same commit go together,
# so that the grammar the checker understands is the one of the model; pass
# --tsvdir <bundle>/tsv/latest.
#
# TestGrammar is built with the copy of PDFium of the repository (an old
# PDFium, with its FreeType, libjpeg, OpenJPEG, LittleCMS and zlib), the PDF
# SDK its README recommends: the checks of indirect objects and --force need
# it.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# ARLINGTON_COMMIT and ARLINGTON_VERSION come from the environment (see
# .github/workflows/ci.yml). ARLINGTON_VERSION is the version of TestGrammar
# at that commit, without the leading v: the build fails when it is not.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

TOOL_ID=arlington
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"

require_versions ARLINGTON_COMMIT ARLINGTON_VERSION

ARLINGTON_DIR="arlington-pdf-model-$ARLINGTON_COMMIT"
fetch arlington "https://github.com/pdf-association/arlington-pdf-model/archive/$ARLINGTON_COMMIT.tar.gz" \
      "arlington-$ARLINGTON_COMMIT.tar.gz" "$ARLINGTON_DIR"
SOURCE="$SRCDIR/$ARLINGTON_DIR"
TESTGRAMMAR="$SOURCE/TestGrammar"

# The version TestGrammar prints: #define TestGrammar_VERSION "v0.81 built ...
source_version="$(sed -n 's/^#define TestGrammar_VERSION "v\([0-9.]*\) .*/\1/p' "$TESTGRAMMAR/src/TestGrammarVers.h")"
[ "$source_version" = "$ARLINGTON_VERSION" ] || {
  echo "TestGrammar is version '$source_version' at $ARLINGTON_COMMIT, expected '$ARLINGTON_VERSION'" >&2; exit 1;
}

# /EHsc (C++ exceptions) is an MSVC option the CMake file passes to every
# Windows compiler; clang targeting MinGW takes it for a file name.
CMAKELISTS="$TESTGRAMMAR/CMakeLists.txt"
awk '$0 == "    add_compile_options(/EHsc)" { print "    if(MSVC)"; print "        add_compile_options(/EHsc)"; print "    endif()"; next } { print }' \
  "$CMAKELISTS" > "$CMAKELISTS.patched"
mv "$CMAKELISTS.patched" "$CMAKELISTS"
grep -F '        add_compile_options(/EHsc)' "$CMAKELISTS" >/dev/null \
  || { echo "the /EHsc option of $CMAKELISTS was not patched" >&2; exit 1; }
# src/Utils.cpp includes <Windows.h>, which only a case-insensitive file
# system finds: the MinGW header is windows.h.
UTILS="$TESTGRAMMAR/src/Utils.cpp"
sed 's/#include <Windows\.h>/#include <windows.h>/' "$UTILS" > "$UTILS.patched"
mv "$UTILS.patched" "$UTILS"
if grep -F '#include <Windows.h>' "$UTILS"; then
  echo "the Windows.h include of $UTILS was not patched" >&2; exit 1
fi

# The PDFium copy crashes when it is destroyed, which TestGrammar already does
# not do on Linux: it does not on MinGW either, as the process exits anyway.
SHIM="$TESTGRAMMAR/src/ArlingtonPDFShimPDFium.cpp"
sed 's/^#if !defined(__linux__) && !defined(DEBUG)$/#if !defined(__linux__) \&\& !defined(__MINGW32__) \&\& !defined(DEBUG)/' "$SHIM" > "$SHIM.patched"
mv "$SHIM.patched" "$SHIM"
grep -F '#if !defined(__linux__) && !defined(__MINGW32__) && !defined(DEBUG)' "$SHIM" >/dev/null \
  || { echo "the PDFium teardown of $SHIM was not patched" >&2; exit 1; }

# TestGrammar has a wmain on Windows, which MinGW links with -municode; on
# the executable only, as the test programs of the configuration have a main.
if ! grep -F 'target_link_options(TestGrammar PRIVATE -municode)' "$CMAKELISTS" >/dev/null; then
  printf '\nif(MINGW)\n    target_link_options(TestGrammar PRIVATE -municode)\nendif()\n' >> "$CMAKELISTS"
fi

# The CHECK macros of the numerics code of the PDFium copy crash on purpose
# with reinterpret_cast<volatile char*>(NULL), which does not compile where
# NULL is nullptr, as with musl.
grep -rl 'reinterpret_cast<volatile char\*>(NULL)' "$TESTGRAMMAR/pdfium" | while read -r numerics_file; do
  sed 's/reinterpret_cast<volatile char\*>(NULL)/reinterpret_cast<volatile char*>(0)/g' "$numerics_file" > "$numerics_file.patched"
  mv "$numerics_file.patched" "$numerics_file"
done
if grep -rl 'reinterpret_cast<volatile char\*>(NULL)' "$TESTGRAMMAR/pdfium"; then
  echo "the NULL casts of the PDFium copy were not patched" >&2; exit 1
fi

# Two Windows files of the PDFium copy only compile with MSVC: the old SAL
# annotations __in, __in_opt and __out, and the results of GetProcAddress
# assigned to void pointers.
WIN32_SOURCES="$TESTGRAMMAR/pdfium/core/src/fxge/win32"
sed -e 's/__in_opt //g' -e 's/__in //g' -e 's/__out //g' "$WIN32_SOURCES/fx_win32_dwrite.cpp" > "$WIN32_SOURCES/fx_win32_dwrite.cpp.patched"
mv "$WIN32_SOURCES/fx_win32_dwrite.cpp.patched" "$WIN32_SOURCES/fx_win32_dwrite.cpp"
sed 's/= GetProcAddress(/= (void*)GetProcAddress(/' "$WIN32_SOURCES/fx_win32_gdipext.cpp" > "$WIN32_SOURCES/fx_win32_gdipext.cpp.patched"
mv "$WIN32_SOURCES/fx_win32_gdipext.cpp.patched" "$WIN32_SOURCES/fx_win32_gdipext.cpp"
if grep -E '(^|[^A-Za-z0-9_])__(in|in_opt|out)([^A-Za-z0-9_]|$)' "$WIN32_SOURCES/fx_win32_dwrite.cpp"; then
  echo "the SAL annotations of fx_win32_dwrite.cpp were not removed" >&2; exit 1
fi

# The executable is written to TestGrammar/bin/<platform>, in the sources.
BUILD="$WORKDIR/build-arlington-testgrammar"
rm -rf "$TESTGRAMMAR/bin/linux" "$TESTGRAMMAR/bin/darwin" "$TESTGRAMMAR/bin/x64"
msg "configuring TestGrammar $ARLINGTON_VERSION ($ARLINGTON_COMMIT) for $TARGET"
# shellcheck disable=SC2086
# -include ostream: src/utils.h uses std::ostream and std::endl without
# including <ostream>, which the libc++ of llvm-mingw does not include
# through the other headers.
cmake -S "$TESTGRAMMAR" -B "$BUILD" $CMAKE_COMMON $CMAKE_CROSS_ARGS -DPDFSDK_PDFIUM=ON \
  "-DCMAKE_CXX_FLAGS=-include ostream" \
  -DCMAKE_EXE_LINKER_FLAGS="$EXE_LDFLAGS"

msg "building TestGrammar"
cmake --build "$BUILD" --parallel "$JOBS" --target TestGrammar

built=""
for candidate in "$TESTGRAMMAR"/bin/*/TestGrammar"$EXE"; do
  if [ -f "$candidate" ]; then built="$candidate"; break; fi
done
[ -n "$built" ] || { echo "TestGrammar$EXE was not built in $TESTGRAMMAR/bin" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Bundle
# ---------------------------------------------------------------------------

BUNDLE="$WORKDIR/arlington-bundle-$TARGET"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
cp "$built" "$BUNDLE/TestGrammar$EXE"
$STRIP "$BUNDLE/TestGrammar$EXE"
chmod 755 "$BUNDLE/TestGrammar$EXE"
cp -R "$SOURCE/tsv" "$BUNDLE/tsv"
cp "$SOURCE/LICENSE" "$BUNDLE/LICENSE"
[ -f "$BUNDLE/tsv/latest/Catalog.tsv" ] || { echo "the bundle has no tsv/latest/Catalog.tsv" >&2; exit 1; }

out="$WORKDIR/TestGrammar-$TARGET.tar.gz"
rm -f "$out"
# The files at the root of the archive. COPYFILE_DISABLE: the tar of macOS
# adds ._ files with the extended attributes otherwise.
( cd "$BUNDLE" && COPYFILE_DISABLE=1 tar -czf "$out" TestGrammar"$EXE" tsv LICENSE )

ls -lh "$BUNDLE/TestGrammar$EXE" "$out"
msg "built TestGrammar for $TARGET"
