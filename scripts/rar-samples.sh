# RAR samples of the smoke tests of scripts/verify-unrar.sh, as base64. rar,
# the RAR archiver, is proprietary: these are test files of libarchive
# (libarchive/test/*.rar.uu at commit 018a1e874d8ecd48fd9d6ec4f90a93960dacc4d8
# of https://github.com/libarchive/libarchive), the distribution of which is
# Copyright Tim Kientzle and available under its BSD 2-Clause License.
#
# - rar4.rar (test_read_format_rar.rar): RAR 4, stored. test.txt and
#   testdir/test.txt ("test text document\r\n"), the symbolic link testlink,
#   and the empty directory testemptydir.
# - rar4-encrypted.rar (test_read_format_rar_encryption_data.rar): RAR 4,
#   compressed (m3) and encrypted (AES-128 of RAR 3), with the password
#   12345678, the headers unencrypted: foo.txt ("data of foo.txt\n") and
#   bar.txt ("data of bar.txt\n").
# - rar4-filter.rar (test_read_format_rar_filter_incomplete_block.rar): RAR 4,
#   compressed with the best method (m5) and a RarVM filter: f2500.bin,
#   10000 bytes.
# - rar5.rar (test_read_format_rar5_compressed.rar): RAR 5, compressed (m5):
#   test.bin, 1200 bytes.
#
# Sourced by scripts/verify-unrar.sh, after it defines fail and sha256_of.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

# rar_sample <name>: the base64 of a sample.
rar_sample() {
  case "$1" in
    rar4.rar) cat <<'BASE64'
UmFyIRoHAM+QcwAADQAAAAAAAACEUnQgkDIAFAAAABQAAAADQqLIvrd22j4UMAgApIEAAHRlc3Qu
dHh0gAi3dto+t3baPnRlc3QgdGV4dCBkb2N1bWVudA0KnS90IJAyAAgAAAAIAAAAA3tEybbRTNg+
FDAIAP+hAAB0ZXN0bGlua8AI0UzYPlBf2j50ZXN0LnR4dM3gdCCQOgAUAAAAFAAAAANCosi+Y3fa
PhQwEACkgQAAdGVzdGRpclx0ZXN0LnR4dMDMY3faPmN32j50ZXN0IHRleHQgZG9jdW1lbnQNCqHI
dOCQMQAAAAAAAAAAAAMAAAAAY3faPhQwBwDtQQAAdGVzdGRpcsDMY3faPmR32j7m53TgkDYAAAAA
AAAAAAADAAAAAJ2r1T4UMAwA7UEAAHRlc3RlbXB0eWRpcoDMnavVPsVd2j7EPXsAQAcA
BASE64
      ;;
    rar4-encrypted.rar) cat <<'BASE64'
UmFyIRoHAM+QcwAADQAAAAAAAABd/HQkhC8AIAAAABAAAAADXIatpqVMMUMdMwcAtIEAAGZvby50
eHRPA7zZ1hZM30VAGpKSiN8VK46ez3C5QOjJR+bO1r9E4rg1qJzoZTcBB0V0JIQvACAAAAAQAAAA
A77ikM2mTDFDHTMHALSBAABiYXIudHh0TwO82dYWTN9wdHpIiYgPZlt95Qa5ch6oJVX4yjcBo+30
8RTzI2TRocQ9ewBABwA=
BASE64
      ;;
    rar4-filter.rar) cat <<'BASE64'
UmFyIRoHAM+QcwAADQAAAAAAAABNYXQgkC4AfwAAABAnAAADnowHE+CwNF0dNQkAtIEAAGYyNTAw
LmJpbgDwGr8wAL+IX9rp/7th0ACJwACQjpeAzSDAdhOkF4S7Nun1IK2sonQLrnC2SKYnH7uABOcY
/wD9CuYWSNfiBzICSRcWCAt6ZJFF02i62JHhxtEru+RdJfCzdHilQWVIVbHhKUf2DTBRM3NmjMPO
vSgs5gmAUsMJpXJiYgAAv4hn9qn/1MQ9ewBABwA=
BASE64
      ;;
    rar5.rar) cat <<'BASE64'
UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAicZf2iYCAwvpAgSwCaSDAs1wynyABQEIdGVzdC5iaW4K
AxOLV6xb+BitHsr0ZQEnZWBUH1V2Xb+UknHJz2WWWQxw2WWTGMWSE4ZCSSThkJCSSSQk45JJIQhJ
JCEJJJCSSEISEs21b3t9Mw6AfR0Drj+eup/3Qf732vfdea86X+gAQAEAyCCfn49vX08vHv7uzr6u
no5+Xk4+Lh4N/d3NrZ19bV1NPS0M/NzMrJyMfGxcTDwb+9vLu5uLe2tbSzsrGvrq2rqqmnpaSjoq
Ggn52cm5mXlpSTSyUjIR6FAfjoyKiYc6cNmoaEgoB+fHt6eHZ0c3Jxb21raWdlY2FfXVtZV1VTIT
f1/I/QJT6JTn+ESXRYowZ5YXajgppimUF+ZC0XadRjLDOMCoR/+glMZpCl9lUKxWVguLAZFoNy4H
deEGwA8xBIyCeZhWNAumoZbYN5uHg4Bgcg+uYROgpnYYDwNt6Hu9h1fQjfxYQI0YMecKHk0Jg2L4
4OY6HCIEqeGFFjtjQ/nxUIBsIQ0IhNIxnJAvJQAdd1ZRAwUEAA==
BASE64
      ;;
    *) fail "no RAR sample named $1" ;;
  esac
}

# The SHA-256 of each sample, and of the files they hold.
RAR_SAMPLE_SHA256="rar4.rar d421b86f6290aefad61b2a36737253b2b30fe27c156bd95abfc230f24fe0307e
rar4-encrypted.rar 84ba9afcf0673aab0d1421d931e76a19294b12117483879c4b58598d3d71e83e
rar4-filter.rar 1200a2ea4a31e36edea13bd3b5b5c6e471e8779da924863b8c1fc02e5979bbd4
rar5.rar 68f9d7e2662cd5bc5607ba9c6bf1edbf121cf3b08011a7d8643091791750a7c8"
RAR_TEST_TXT_SHA256=5a5f16e01faf8adf92eb4499a2d3e93010c4b41dbb7f698f4a8466d9f58e6dd2
RAR_FOO_TXT_SHA256=325d7b459b439684cad8825cbf2e488de15518103de09c56a42d6b1875081ee7
RAR_BAR_TXT_SHA256=7113d093a90b4a5cbac15a3bc8e85efbac50556c2a1f58f70a283cb2c373f1d5
RAR_F2500_BIN_SHA256=0aa5515fef1e70bf15fc5ec629771a9ee6029e49782df8bee9791add8690d020
RAR_TEST_BIN_SHA256=588870a2dade35c2650fbb7898c9a9c7f21fce7c281198604e8d0c9737f2c375

# write_rar_samples: writes the samples to the current directory, and checks
# that each one has its pinned content.
write_rar_samples() {
  printf '%s\n' "$RAR_SAMPLE_SHA256" | while read -r name sha; do
    rar_sample "$name" | tr -d '\r' | base64 -d > "$name" || fail "could not decode $name"
    [ "$(sha256_of "$name")" = "$sha" ] || fail "$name does not have the SHA-256 $sha"
  done
}
