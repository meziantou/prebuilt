# The barcodes the smoke tests of scripts/verify-zint.sh,
# scripts/verify-zxing-cpp.sh and scripts/verify-zbar.sh write with zint and
# decode with ZXingReader and zbarimg. Sourced by these scripts.
#
# One line per barcode, with fields separated by '|':
#
#   name | zint options | data | ZXingReader options | ZXingReader -1 result | symbol | zbarimg options | zbarimg result
#
# - The zint options pin the symbol: -b is the symbology, --vers the version
#   (the size of a QR Code, or the check digit of Code 39), --mask the mask
#   and --secure the error correction level.
# - The ZXingReader result is what `ZXingReader -1` prints after the file
#   name: the format and the quoted text. EAN/UPC codes with an add-on are
#   reported twice, with and without it: the result is one of the lines.
#   ZXingReader reports UPC-A as EAN-13 unless it is asked for UPC-A only.
# - The symbol is the version, error correction level and mask ZXingReader
#   reports for a QR Code, Micro QR or rMQR symbol, which are the ones the zint
#   options pin (rMQR has a single mask, 4); it is empty for linear barcodes.
#   For these symbols, scripts/verify-zxing-cpp.sh also compares the module
#   matrix ZXingReader detects with the one zint dumps.
# - The zbarimg result is the lines of `zbarimg -q`, separated by ';': the type
#   and the text of each symbol. zbar reports an add-on as a symbol of its own
#   (EAN-2, EAN-5), and only when it is enabled with -Sean2.enable or
#   -Sean5.enable; it reports UPC-A as EAN-13 unless -Supca.enable. "-" is a
#   barcode zbar cannot read: Micro QR and rMQR.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

BARCODE_SAMPLES='
qr|-b 58 --vers=2 --mask=3 --secure=2|Hello, World!||QR Code "Hello, World!"|2/M/3||QR-Code:Hello, World!
qr-h|-b 58 --vers=3 --mask=6 --secure=4|https://example.com/?q=1||QR Code "https://example.com/?q=1"|3/H/6||QR-Code:https://example.com/?q=1
microqr|-b 97 --vers=2 --mask=1 --secure=2|12345||Micro QR Code "12345"|M2/M/1||-
microqr-m4|-b 97 --vers=4 --mask=2 --secure=1|MICRO QR 4||Micro QR Code "MICRO QR 4"|M4/L/2||-
rmqr|-b 145 --vers=1 --secure=2|ABC123||rMQR Code "ABC123"|R7x43/M/4||-
rmqr-h|-b 145 --vers=13 --secure=4|rMQR 2026||rMQR Code "rMQR 2026"|R11x59/H/4||-
code128|-b 20|Code128-Test||Code 128 "Code128-Test"|||CODE-128:Code128-Test
code39|-b 8|CODE39||Code 39 "CODE39"|||CODE-39:CODE39
code39-check|-b 8 --vers=1|CODE39||Code 39 "CODE39W"|||CODE-39:CODE39W
code93|-b 25|CODE93||Code 93 "CODE93"|||CODE-93:CODE93
ean8|-b 10|1234567||EAN-8 "12345670"|||EAN-8:12345670
ean8-addon2|-b 10|1234567+12||EAN-8 "1234567012"||-Sean2.enable|EAN-8:12345670;EAN-2:12
ean8-addon5|-b 10|1234567+12345||EAN-8 "1234567012345"||-Sean5.enable|EAN-8:12345670;EAN-5:12345
ean13|-b 15|123456789012||EAN-13 "1234567890128"|||EAN-13:1234567890128
ean13-addon2|-b 15|123456789012+12||EAN-13 "123456789012812"||-Sean2.enable|EAN-13:1234567890128;EAN-2:12
ean13-addon5|-b 15|123456789012+12345||EAN-13 "123456789012812345"||-Sean5.enable|EAN-13:1234567890128;EAN-5:12345
upca|-b 34|12345678901|-formats UPC-A|UPC-A "0123456789012"||-Supca.enable|UPC-A:123456789012
upca-addon2|-b 34|12345678901+12|-formats UPC-A|UPC-A "012345678901212"||-Sean2.enable|EAN-13:0123456789012;EAN-2:12
upca-addon5|-b 34|12345678901+12345|-formats UPC-A|UPC-A "012345678901212345"||-Sean5.enable|EAN-13:0123456789012;EAN-5:12345
codabar|-b 18|A123456B||Codabar "A123456B"|||Codabar:A123456B
itf|-b 3|12345678901231||ITF "12345678901231"|||I2/5:12345678901231
'

# barcode_samples: the lines of BARCODE_SAMPLES, without the empty ones.
barcode_samples() {
  printf '%s\n' "$BARCODE_SAMPLES" | sed '/^$/d'
}

# write_barcode <zint> <name> <zint options> <data>: writes <name>.png with
# zint, at 4 pixels per module, with the quiet zones of the symbology.
write_barcode() {
  zint="$1"; name="$2"; options="$3"; data="$4"
  rm -f "$name.png"
  # shellcheck disable=SC2086
  "$zint" $options --scale=4 --quietzones -d "$data" -o "$name.png" > zint.log 2>&1 \
    || { cat zint.log >&2; fail "$name: zint $options failed"; }
  [ "$(od -An -tx1 -N 8 "$name.png" | tr -d ' \n\r')" = "89504e470d0a1a0a" ] \
    || { cat zint.log >&2; fail "$name: zint did not write a PNG file"; }
}
