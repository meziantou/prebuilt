#!/usr/bin/env bash
#
# Builds the veraPDF bundle: the veraPDF command-line validator (PDF/A and
# PDF/UA) with a Java runtime cut to the modules it uses (jlink), so that it
# needs no Java installed:
#
#   verapdf-<target>.tar.gz
#     verapdf          (POSIX shell launcher; verapdf.exe on Windows)
#     lib/verapdf-cli.jar
#     runtime/         (the jlink image of Eclipse Temurin, with its legal/ folder)
#
#   bash scripts/build-verapdf.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# veraPDF publishes its releases as an IzPack installer, which is run without
# prompts to get the CLI jar. The Java runtime is linked with the jlink of a
# Temurin JDK for the build machine, from the jmods of the Temurin JDK of the
# target: win-x64 is linked on Linux from the Windows JDK, and its launcher,
# scripts/verapdf-launcher.c, is cross-compiled with llvm-mingw (point
# LLVM_MINGW_ROOT at the extracted toolchain). The other targets build
# natively. The Linux runtimes need glibc: Temurin's Linux JDKs are linked
# with it.
#
# The modules are the ones jdeps finds in the CLI jar, plus the ones it cannot
# see: jdk.charsets (the encodings of PDF files), jdk.crypto.ec (signatures),
# jdk.zipfs and jdk.unsupported.
#
# VERAPDF_VERSION and TEMURIN_VERSION come from the environment (see
# .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

TOOL_ID=verapdf
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"

require_versions VERAPDF_VERSION TEMURIN_VERSION

# ---------------------------------------------------------------------------
# Temurin JDKs
# ---------------------------------------------------------------------------

# 21.0.12.1+1: the release tag is jdk-21.0.12.1+1, the files are named
# 21.0.12.1_1.
TEMURIN_MAJOR="${TEMURIN_VERSION%%.*}"
TEMURIN_FILE_VERSION="$(echo "$TEMURIN_VERSION" | tr + _)"
TEMURIN_TAG="jdk-$(echo "$TEMURIN_VERSION" | sed 's/+/%2B/')"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# fetch_jdk <os> <arch>: downloads and extracts the JDK, checked against the
# checksum Adoptium publishes next to it, and sets JDK_HOME. Not run in a
# command substitution, where set -e does not apply.
fetch_jdk() {
  jdk_os="$1"; jdk_arch="$2"
  extension="tar.gz"
  if [ "$jdk_os" = "windows" ]; then extension="zip"; fi
  name="OpenJDK${TEMURIN_MAJOR}U-jdk_${jdk_arch}_${jdk_os}_hotspot_${TEMURIN_FILE_VERSION}.$extension"
  jdk_dir="$SRCDIR/jdk-$TEMURIN_FILE_VERSION-$jdk_os-$jdk_arch"
  if [ ! -d "$jdk_dir" ]; then
    url="https://github.com/adoptium/temurin${TEMURIN_MAJOR}-binaries/releases/download/$TEMURIN_TAG/$name"
    msg "fetching Temurin $TEMURIN_VERSION ($jdk_os $jdk_arch)"
    curl -fsSL --retry 5 --connect-timeout 30 "$url" -o "$SRCDIR/$name"
    curl -fsSL --retry 5 --connect-timeout 30 "$url.sha256.txt" -o "$SRCDIR/$name.sha256.txt"
    expected="$(cut -d ' ' -f 1 < "$SRCDIR/$name.sha256.txt")"
    actual="$(sha256_of "$SRCDIR/$name")"
    [ "$expected" = "$actual" ] || { echo "the SHA-256 of $name is $actual, expected $expected" >&2; exit 1; }
    rm -rf "$jdk_dir.tmp"
    mkdir -p "$jdk_dir.tmp"
    if [ "$extension" = "zip" ]; then
      ( cd "$jdk_dir.tmp" && unzip -q "$SRCDIR/$name" )
    else
      tar -xzf "$SRCDIR/$name" -C "$jdk_dir.tmp"
    fi
    mv "$jdk_dir.tmp" "$jdk_dir"
  fi
  JDK_HOME=""
  for candidate in "$jdk_dir"/jdk-*; do
    if [ -d "$candidate/Contents/Home" ]; then candidate="$candidate/Contents/Home"; fi
    if [ -d "$candidate/jmods" ]; then JDK_HOME="$candidate"; fi
  done
  [ -n "$JDK_HOME" ] || { echo "no JDK with jmods in $jdk_dir" >&2; exit 1; }
}

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) fetch_jdk linux x64 ;;
  Linux-aarch64|Linux-arm64) fetch_jdk linux aarch64 ;;
  Darwin-arm64) fetch_jdk mac aarch64 ;;
  *) echo "no Temurin JDK for the build machine $(uname -s) $(uname -m)" >&2; exit 2 ;;
esac
HOST_JDK="$JDK_HOME"

case "$TARGET" in
  linux-x64) fetch_jdk linux x64 ;;
  linux-arm64) fetch_jdk linux aarch64 ;;
  win-x64) fetch_jdk windows x64 ;;
  osx-arm64) fetch_jdk mac aarch64 ;;
esac
TARGET_JDK="$JDK_HOME"

# ---------------------------------------------------------------------------
# veraPDF
# ---------------------------------------------------------------------------

VERAPDF_MINOR="$(echo "$VERAPDF_VERSION" | cut -d . -f 1-2)"
fetch verapdf "https://software.verapdf.org/releases/$VERAPDF_MINOR/verapdf-greenfield-$VERAPDF_VERSION-installer.zip" \
      "verapdf-greenfield-$VERAPDF_VERSION-installer.zip" "verapdf-greenfield-$VERAPDF_VERSION"

# The installer asks for nothing when it is given the answers. The GUI pack is
# installed because the installer requires it; only the CLI jar is kept.
INSTALL="$WORKDIR/build-verapdf-install"
rm -rf "$INSTALL"
cat > "$WORKDIR/build-verapdf-auto-install.xml" <<XML
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<AutomatedInstallation langpack="eng">
    <com.izforge.izpack.panels.htmlhello.HTMLHelloPanel id="welcome"/>
    <com.izforge.izpack.panels.target.TargetPanel id="install_dir">
        <installpath>$INSTALL</installpath>
    </com.izforge.izpack.panels.target.TargetPanel>
    <com.izforge.izpack.panels.packs.PacksPanel id="sdk_pack_select">
        <pack index="0" name="veraPDF GUI" selected="true"/>
        <pack index="1" name="veraPDF Mac and *nix Scripts" selected="true"/>
        <pack index="2" name="veraPDF Validation model" selected="false"/>
        <pack index="3" name="veraPDF Documentation" selected="false"/>
        <pack index="4" name="veraPDF Sample Plugins" selected="false"/>
    </com.izforge.izpack.panels.packs.PacksPanel>
    <com.izforge.izpack.panels.install.InstallPanel id="install"/>
    <com.izforge.izpack.panels.finish.FinishPanel id="finish"/>
</AutomatedInstallation>
XML
msg "installing veraPDF $VERAPDF_VERSION"
"$HOST_JDK/bin/java" -jar "$SRCDIR/verapdf-greenfield-$VERAPDF_VERSION/verapdf-izpack-installer-$VERAPDF_VERSION.jar" \
  "$WORKDIR/build-verapdf-auto-install.xml" > "$WORKDIR/build-verapdf-install.log" 2>&1 \
  || { cat "$WORKDIR/build-verapdf-install.log" >&2; exit 1; }
CLI_JAR="$INSTALL/bin/cli-$VERAPDF_VERSION.jar"
[ -f "$CLI_JAR" ] || { echo "the installer wrote no $CLI_JAR" >&2; exit 1; }
grep -F 'org.verapdf.apps.GreenfieldCliWrapper' "$INSTALL/verapdf" >/dev/null \
  || { echo "the main class of the CLI script is not org.verapdf.apps.GreenfieldCliWrapper" >&2; exit 1; }

# The jar bundles the module-info of libraries whose modules are not in it
# (java.xml.bind needs java.activation), which jdeps refuses: the classes are
# analysed without them.
CLASSES="$WORKDIR/build-verapdf-classes"
rm -rf "$CLASSES"
mkdir -p "$CLASSES"
( cd "$CLASSES" && "$HOST_JDK/bin/jar" xf "$CLI_JAR" )
find "$CLASSES" -name module-info.class -exec rm -f {} +
MODULES="$("$HOST_JDK/bin/jdeps" --multi-release "$TEMURIN_MAJOR" --ignore-missing-deps --print-module-deps "$CLASSES" | tail -n 1)"
case "$MODULES" in
  java.base*) ;;
  *) echo "jdeps found no modules: $MODULES" >&2; exit 1 ;;
esac
MODULES="$MODULES,jdk.charsets,jdk.crypto.ec,jdk.zipfs,jdk.unsupported"
echo "modules: $MODULES"

# ---------------------------------------------------------------------------
# Bundle
# ---------------------------------------------------------------------------

BUNDLE="$WORKDIR/verapdf-bundle-$TARGET"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/lib"

msg "linking the Java runtime for $TARGET"
"$HOST_JDK/bin/jlink" --module-path "$TARGET_JDK/jmods" --add-modules "$MODULES" \
  --strip-debug --no-man-pages --no-header-files --compress=zip-6 --output "$BUNDLE/runtime"
cp "$CLI_JAR" "$BUNDLE/lib/verapdf-cli.jar"

case "$TARGET" in
  win-x64)
    [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
    [ -f "$BUNDLE/runtime/bin/java.exe" ] || { echo "the runtime has no bin/java.exe" >&2; exit 1; }
    msg "building verapdf.exe"
    "$MINGW_TRIPLE-clang" -municode -O2 -static -Wall -Werror -o "$BUNDLE/verapdf.exe" "$SCRIPT_DIR/verapdf-launcher.c"
    $STRIP "$BUNDLE/verapdf.exe"
    LAUNCHER="verapdf.exe"
    ;;
  *)
    [ -f "$BUNDLE/runtime/bin/java" ] || { echo "the runtime has no bin/java" >&2; exit 1; }
    # The options of the CLI script of the installer ($INSTALL/verapdf).
    cat > "$BUNDLE/verapdf" <<'SH'
#!/bin/sh
# veraPDF command-line validator, with the Java runtime of this bundle.
bundle="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$bundle/runtime/bin/java" -Dfile.encoding=UTF8 -Djava.awt.headless=true -XX:+IgnoreUnrecognizedVMOptions \
  "-Dapp.name=VeraPDF validation CLI" "-Dapp.home=$bundle" "-Dbasedir=$bundle" \
  --add-exports=java.base/sun.security.pkcs=ALL-UNNAMED \
  -classpath "$bundle/lib/verapdf-cli.jar" org.verapdf.apps.GreenfieldCliWrapper "$@"
SH
    chmod 755 "$BUNDLE/verapdf"
    LAUNCHER="verapdf"
    ;;
esac

out="$WORKDIR/verapdf-$TARGET.tar.gz"
rm -f "$out"
# COPYFILE_DISABLE: the tar of macOS adds ._ files with the extended
# attributes otherwise.
( cd "$BUNDLE" && COPYFILE_DISABLE=1 tar -czf "$out" "$LAUNCHER" lib runtime )

du -sh "$BUNDLE/runtime"
ls -lh "$out"
msg "built the veraPDF bundle for $TARGET"
