# Helpers of the verify scripts of the image tools added with
# scripts/verify-astcenc.sh: linkage assertions, comparisons and byte dumps.
# Sourced by them, after they define TARGET, fail, ok and contains.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

# The llvm-mingw objdump comes first: the Windows binaries are checked on the
# Linux machine that cross-compiles them.
find_objdump() {
  for candidate in x86_64-w64-mingw32-objdump objdump llvm-objdump; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# assert_linkage <binary>: fully static on Linux, system dylibs only on macOS,
# system DLLs only on Windows.
assert_linkage() {
  linkage_bin="$1"
  case "$TARGET" in
    linux-*)
      description="$(file "$linkage_bin")"
      contains "$description" 'statically linked' || contains "$description" 'static-pie linked' \
        || fail "$linkage_bin is not statically linked: $description"
      # ldd exits non-zero on a static binary, hence no `set -e` trip here.
      if ldd "$linkage_bin" 2>/dev/null | grep -q '=>'; then
        fail "$linkage_bin has dynamic dependencies: $(ldd "$linkage_bin" 2>/dev/null)"
      fi
      ok "$linkage_bin is fully static"
      ;;
    osx-arm64)
      deps="$(otool -L "$linkage_bin" | tail -n +2 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*(.*$//' \
              | grep -v '^/usr/lib/' | grep -v '^/System/Library/' || true)"
      [ -z "$deps" ] || fail "$linkage_bin links non-system dylibs: $deps"
      ok "$linkage_bin links only system dylibs"
      ;;
    win-*)
      objdump="$(find_objdump)" || fail "no objdump or llvm-objdump to list the imports of $linkage_bin"
      imports="$("$objdump" -p "$linkage_bin" | sed -n 's/^[[:space:]]*DLL Name: //p' \
                 | tr 'A-Z' 'a-z' | tr -d '\r' | sort -u)"
      [ -n "$imports" ] || fail "could not list the imports of $linkage_bin"
      bad=""
      for dll in $imports; do
        # DLLs that ship with Windows; ucrtbase and the api-ms-win-crt-* stubs
        # are the UCRT, a Windows component since Windows 10.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|ws2_32.dll|bcrypt.dll|shlwapi.dll|windowscodecs.dll|version.dll|ucrtbase.dll|api-ms-win-*) ;;
          *) bad="$bad $dll" ;;
        esac
      done
      [ -z "$bad" ] || fail "$linkage_bin imports non-system DLLs:$bad"
      ok "$linkage_bin imports only system DLLs"
      ;;
  esac
}

# expect <label> <actual> <expected>
expect() {
  [ "$2" = "$3" ] || fail "$1:
  actual:   $2
  expected: $3"
  ok "$1"
}

# The decimal bytes of a file, separated by spaces.
dec() {
  od -An -v -tu1 "$1" | tr -s ' \n\r' '   ' | sed -e 's/^ //' -e 's/ $//'
}

# same_file <label> <actual file> <expected file>
same_file() {
  [ -f "$2" ] || fail "$1: $2 was not written"
  cmp -s "$2" "$3" || fail "$1:
  $2: $(dec "$2" | cut -c1-200)
  $3: $(dec "$3" | cut -c1-200)"
  ok "$1"
}

# hex_of_n <file> <count>: the hexadecimal digits of the first bytes of a file.
hex_of_n() {
  od -An -v -tx1 -N "$2" "$1" | tr -d ' \n\r'
}

file_size() {
  echo $(($(wc -c < "$1")))
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}
