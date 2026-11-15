#!/usr/bin/env bash
#
# Verifies the iccDEV (DemoIccMAX) tools built by scripts/build-iccdev.sh:
# iccFromXml, iccToXml, iccFromJson, iccToJson, iccDumpProfile, iccRoundTrip,
# iccApplyNamedCmm and iccApplyToLink.
#
#   bash scripts/verify-iccdev.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage and version assertions only
#   run   version assertions plus the tests below (must run on the target)
#   all   both (default)
#
# The tests write the XML of two iccMAX (version 5) profiles:
# - a display profile with a D2B0 and a B2D0 tag (multiProcessElementType: a
#   matrix element with constants), and the matrix and TRC tags a display
#   profile needs: iccFromXml writes it, iccDumpProfile -v finds it valid,
#   iccApplyNamedCmm applies D2B0 (RGB to XYZ, floats) and D2B0 then B2D0 (the
#   values come back), iccToXml and iccToJson write it, and iccFromXml and
#   iccFromJson write the same bytes again from them;
# - a named color profile (nmcl, a namedColorTag of namedColorStructure with
#   a tint zero): iccApplyNamedCmm gives the PCS values of named colors and
#   their tints;
# and convert a version 2 profile (scripts/psd-samples.sh) to XML and back.
#
# ICCDEV_LIBRARY_VERSION comes from the environment (see
# .github/workflows/ci.yml): the version the tools print.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
[ -n "$ICCDEV_LIBRARY_VERSION" ] || { echo "ICCDEV_LIBRARY_VERSION is not set" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

TOOLS="iccFromXml iccToXml iccFromJson iccToJson iccDumpProfile iccRoundTrip iccApplyNamedCmm iccApplyToLink"
for tool in $TOOLS; do
  [ -f "./$tool-$TARGET$EXE" ] || { echo "missing ./$tool-$TARGET$EXE" >&2; exit 1; }
  chmod +x "./$tool-$TARGET$EXE" 2>/dev/null || true
done

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
# shellcheck source=psd-samples.sh
. "$SCRIPT_DIR/psd-samples.sh"

# header <class> <data color space> <PCS> <description>: the start of the XML
# of a version 5 profile, to its white point tag.
header() {
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<IccProfile>\n  <Header>\n'
  printf '    <PreferredCMMType></PreferredCMMType>\n    <ProfileVersion>5.0</ProfileVersion>\n'
  printf '    <ProfileDeviceClass>%s</ProfileDeviceClass>\n    <DataColourSpace>%s</DataColourSpace>\n    <PCS>%s</PCS>\n' "$1" "$2" "$3"
  printf '    <CreationDateTime>2026-01-01T00:00:00</CreationDateTime>\n'
  printf '    <ProfileFlags EmbeddedInFile="false" UseWithEmbeddedDataOnly="false"/>\n'
  printf '    <DeviceAttributes ReflectiveOrTransparency="reflective" GlossyOrMatte="glossy" MediaPolarity="positive" MediaColour="colour"/>\n'
  printf '    <RenderingIntent>Relative</RenderingIntent>\n'
  printf '    <PCSIlluminant>\n      <XYZNumber X="0.9642" Y="1.0" Z="0.8249"/>\n    </PCSIlluminant>\n'
  printf '    <ProfileCreator></ProfileCreator>\n    <ProfileID>1</ProfileID>\n  </Header>\n  <Tags>\n'
  printf '    <profileDescriptionTag> <multiLocalizedUnicodeType>\n'
  printf '      <LocalizedText LanguageCountry="enUS"><![CDATA[%s]]></LocalizedText>\n' "$4"
  printf '    </multiLocalizedUnicodeType> </profileDescriptionTag>\n'
  printf '    <copyrightTag> <multiLocalizedUnicodeType>\n'
  printf '      <LocalizedText LanguageCountry="enUS"><![CDATA[No copyright]]></LocalizedText>\n'
  printf '    </multiLocalizedUnicodeType> </copyrightTag>\n'
  printf '    <mediaWhitePointTag> <XYZArrayType>\n      <XYZNumber X="0.9642" Y="1.0" Z="0.8249"/>\n    </XYZArrayType> </mediaWhitePointTag>\n'
}

# matrix_element <tag> <3 x 3 matrix> <3 constants>: a multiProcessElementType.
matrix_element() {
  printf '    <multiProcessElementType>\n      <TagSignature>%s</TagSignature>\n' "$1"
  printf '      <MultiProcessElements InputChannels="3" OutputChannels="3">\n'
  printf '        <MatrixElement InputChannels="3" OutputChannels="3">\n'
  printf '          <MatrixData>%s</MatrixData>\n          <ConstantData>%s</ConstantData>\n' "$2" "$3"
  printf '        </MatrixElement>\n      </MultiProcessElements>\n    </multiProcessElementType>\n'
}

# named_color <name> <L a b>
named_color() {
  printf '        <tagStructType> <namedColorStructure> <MemberTags>\n'
  printf '          <nmclNameNmClrMbr> <utf8Type> <TextData><![CDATA[%s]]></TextData> </utf8Type> </nmclNameNmClrMbr>\n' "$1"
  printf '          <nmclPcsDataMbr> <float16ArrayType> <Data>%s</Data> </float16ArrayType> </nmclPcsDataMbr>\n' "$2"
  printf '        </MemberTags> </namedColorStructure> </tagStructType>\n'
}

# values <iccApplyNamedCmm output>: the lines of values, blanks squeezed,
# separated by '|'.
values() {
  tr -d '\r' | grep -v '^;' | grep -v '^[[:space:]]*$' | tr -s ' \t' ' ' | sed 's/^ //' | tr '\n' '|'
}

# run <label> <binary> <arguments...>
run() {
  run_label="$1"; shift
  "$@" > tool.log 2>&1 || { cat tool.log >&2; fail "$run_label failed: $*"; }
}

tests() {
  workdir="smoke-iccdev-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  T="-$TARGET$EXE"

  # D2B0: X = 0.5 R + 0.0625, Y = 0.25 G, Z = 2 B; B2D0 is its inverse.
  {
    header mntr 'RGB ' 'XYZ ' 'Prebuilt D2B0 and B2D0'
    printf '    <redColorantTag> <XYZArrayType> <XYZNumber X="0.5" Y="0" Z="0"/> </XYZArrayType> </redColorantTag>\n'
    printf '    <greenColorantTag> <XYZArrayType> <XYZNumber X="0" Y="0.25" Z="0"/> </XYZArrayType> </greenColorantTag>\n'
    printf '    <blueColorantTag> <XYZArrayType> <XYZNumber X="0" Y="0" Z="2"/> </XYZArrayType> </blueColorantTag>\n'
    printf '    <redTRCTag> <curveType> <Curve>256</Curve> </curveType> </redTRCTag>\n'
    printf '    <greenTRCTag SameAs="redTRCTag"/>\n    <blueTRCTag SameAs="redTRCTag"/>\n'
    matrix_element D2B0 "0.5 0 0 0 0.25 0 0 0 2" "0.0625 0 0"
    matrix_element B2D0 "2 0 0 0 4 0 0 0 0.5" "-0.125 0 0"
    printf '  </Tags>\n</IccProfile>\n'
  } > d2b.xml

  msg "iccFromXml, iccDumpProfile: a version 5 display profile with D2B0 and B2D0"
  run "iccFromXml" "../iccFromXml$T" d2b.xml d2b.icc
  contains "$(cat tool.log)" "Profile parsed and saved correctly" || fail "iccFromXml: $(cat tool.log)"
  ok "iccFromXml: Profile parsed and saved correctly"
  run "iccDumpProfile" "../iccDumpProfile$T" -v d2b.icc
  dump="$(tr -d '\r' < tool.log)"
  for text in "Version:            5.00" "Profile Class:      Display" "'D2B0'" "'B2D0'" "Profile is valid for version 5.00"; do
    contains "$dump" "$text" || fail "iccDumpProfile -v has no '$text': $dump"
    ok "iccDumpProfile -v: $text"
  done

  msg "iccApplyNamedCmm: D2B0 and B2D0"
  printf "'RGB '\t; Data Format\nicEncodeFloat\t; Encoding\n\n1 0 0\n0 1 0\n0 0 1\n0.5 0.25 0.75\n" > rgb.txt
  "../iccApplyNamedCmm$T" rgb.txt 3 0 d2b.icc 1 > apply.txt 2>&1 || { cat apply.txt >&2; fail "iccApplyNamedCmm failed"; }
  expect "D2B0: RGB to XYZ" "$(values < apply.txt)" \
    "'XYZ ' ; Data Format|icEncodeFloat ; Encoding|0.5625 0.0000 0.0000 ; 1.0000 0.0000 0.0000|0.0625 0.2500 0.0000 ; 0.0000 1.0000 0.0000|0.0625 0.0000 2.0000 ; 0.0000 0.0000 1.0000|0.3125 0.0625 1.5000 ; 0.5000 0.2500 0.7500|"
  "../iccApplyNamedCmm$T" rgb.txt 3 0 d2b.icc 1 d2b.icc 1 > apply.txt 2>&1 || { cat apply.txt >&2; fail "iccApplyNamedCmm failed"; }
  expect "D2B0 then B2D0: the values come back" "$(values < apply.txt)" \
    "'RGB ' ; Data Format|icEncodeFloat ; Encoding|1.0000 0.0000 0.0000 ; 1.0000 0.0000 0.0000|0.0000 1.0000 0.0000 ; 0.0000 1.0000 0.0000|0.0000 0.0000 1.0000 ; 0.0000 0.0000 1.0000|0.5000 0.2500 0.7500 ; 0.5000 0.2500 0.7500|"

  msg "iccToXml, iccToJson and back"
  run "iccToXml" "../iccToXml$T" d2b.icc again.xml
  run "iccFromXml" "../iccFromXml$T" again.xml again.icc
  same_file "iccToXml then iccFromXml: the same bytes" again.icc d2b.icc
  run "iccToJson" "../iccToJson$T" d2b.icc d2b.json
  contains "$(cat d2b.json)" '"DToB0Tag"' || fail "the JSON has no DToB0Tag"
  run "iccFromJson" "../iccFromJson$T" d2b.json json.icc
  same_file "iccToJson then iccFromJson: the same bytes" json.icc d2b.icc
  write_test_icc v2.icc
  run "iccToXml of a version 2 profile" "../iccToXml$T" v2.icc v2.xml
  contains "$(cat v2.xml)" "Prebuilt test RGB" || fail "the XML of the version 2 profile has no description"
  run "iccFromXml of a version 2 profile" "../iccFromXml$T" v2.xml v2-again.icc
  run "iccDumpProfile" "../iccDumpProfile$T" -v v2-again.icc
  contains "$(tr -d '\r' < tool.log)" "Version:            2.10" || fail "iccDumpProfile of the version 2 profile: $(cat tool.log)"
  ok "a version 2 profile: iccToXml, iccFromXml, version 2.10"

  msg "named colors"
  {
    header nmcl '' 'Lab ' 'Prebuilt named colors'
    printf '    <namedColorTag> <tagArrayType> <namedColorArray> <ArrayTags>\n'
    printf '        <tagStructType> <tintZeroStructure> <MemberTags>\n'
    printf '          <tnt0PcsDataMbr> <float16ArrayType> <Data>100 0 0</Data> </float16ArrayType> </tnt0PcsDataMbr>\n'
    printf '        </MemberTags> </tintZeroStructure> </tagStructType>\n'
    named_color Black "0 0 0"
    named_color Red "50 64 32"
    named_color Blue "25 16 -64"
    printf '    </ArrayTags> </namedColorArray> </tagArrayType> </namedColorTag>\n  </Tags>\n</IccProfile>\n'
  } > named.xml
  run "iccFromXml" "../iccFromXml$T" named.xml named.icc
  run "iccDumpProfile" "../iccDumpProfile$T" -v named.icc
  dump="$(tr -d '\r' < tool.log)"
  for text in "Profile Class:      NamedColor" "namedColorTag  'nmcl'" "Profile is valid for version 5.00"; do
    contains "$dump" "$text" || fail "iccDumpProfile -v has no '$text': $dump"
    ok "iccDumpProfile -v: $text"
  done
  printf "'nmcl'\t; Data Format\nicEncodeValue\t; Encoding\n\n{ \"Red\" } 1.0\n{ \"Red\" } 0.5\n{ \"Blue\" } 1\n{ \"Black\" } 1\n" > named.txt
  "../iccApplyNamedCmm$T" named.txt 0 0 named.icc 3 > apply.txt 2>&1 || { cat apply.txt >&2; fail "iccApplyNamedCmm of named colors failed"; }
  expect "the Lab values of named colors and tints" "$(values < apply.txt)" \
    "'Lab ' ; Data Format|icEncodeValue ; Encoding|"'50.0000 64.0000 32.0000 ;{ "Red" } 1.0000|75.0000 32.0000 16.0000 ;{ "Red" } 0.5000|25.0000 16.0000 -64.0000 ;{ "Blue" } 1.0000|0.0000 0.0000 0.0000 ;{ "Black" } 1.0000|'

  msg "iccRoundTrip, iccApplyToLink"
  run "iccRoundTrip" "../iccRoundTrip$T" d2b.icc 1
  contains "$(tr -d '\r' < tool.log)" "Round Trip Results" || fail "iccRoundTrip: $(cat tool.log)"
  ok "iccRoundTrip reports the round trip of the profile"
  usage="$("../iccApplyToLink$T" 2>&1 | tr -d '\r' || true)"
  contains "$usage" "iccApplyToLink" || fail "iccApplyToLink: $usage"
  ok "iccApplyToLink prints its usage"

  cd ..
  ok "all tests passed"
}

case "$MODE" in
  link|all)
    msg "linkage and version ($TARGET)"
    for tool in $TOOLS; do
      assert_linkage "./$tool-$TARGET$EXE"
      grep -a -q -F "$ICCDEV_LIBRARY_VERSION" "./$tool-$TARGET$EXE" || fail "$tool does not contain '$ICCDEV_LIBRARY_VERSION'"
    done
    ok "the tools contain IccProfLib version $ICCDEV_LIBRARY_VERSION"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    banner="$("./iccApplyNamedCmm-$TARGET$EXE" 2>&1 | tr -d '\r' || true)"
    contains "$banner" "built with IccProfLib version $ICCDEV_LIBRARY_VERSION" || fail "iccApplyNamedCmm: $banner"
    ok "iccApplyNamedCmm: built with IccProfLib version $ICCDEV_LIBRARY_VERSION"
    tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
