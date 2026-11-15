"""Installs pinned wheels from PyPI into the site-packages of the psd-tools bundle.

    python3 -I psd-tools-wheels.py <target> <python version> <site-packages> <lock file> <name>==<version>...

Run by scripts/build-psd-tools.sh with the Python of the build machine, which
is not the Python of the bundle when win-x64 is built on Linux: no pip, no
resolver. Each requirement is an exact version, and its dependencies are
other requirements of the command line. For each one, the wheel for the
target is picked among the files PyPI lists for that version, downloaded,
checked against the SHA-256 PyPI publishes, and extracted (a wheel is a zip
file). The lock file gets one "<file name> <sha256>" line per wheel.

The wheel for a target is the one for CPython <python version> (cpXY-cpXY,
then the highest cpXY-abi3, then py3-none), for the platform of the target
(manylinux glibc wheels for Linux, not musllinux; win_amd64; macOS arm64),
with the oldest platform version: the oldest glibc, the oldest macOS.
"""

import hashlib
import json
import os
import re
import sys
import time
import urllib.request
import zipfile

PLATFORMS = {
    "linux-x64": re.compile(r"^manylinux_(\d+)_(\d+)_x86_64$|^manylinux(2014|2010|1)_x86_64$"),
    "linux-arm64": re.compile(r"^manylinux_(\d+)_(\d+)_aarch64$|^manylinux(2014)_aarch64$"),
    "win-x64": re.compile(r"^win_amd64$"),
    "osx-arm64": re.compile(r"^macosx_(\d+)_(\d+)_(?:arm64|universal2)$"),
}

# The glibc version of the legacy manylinux tags.
LEGACY_MANYLINUX = {"1": (2, 5), "2010": (2, 12), "2014": (2, 17)}


def fetch(url):
    for attempt in range(1, 6):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                return response.read()
        except OSError as error:
            if attempt == 5:
                raise
            print(f"download attempt {attempt} failed: {url}: {error}", file=sys.stderr)
            time.sleep(2 * attempt)
    raise AssertionError


def platform_rank(target, platform):
    """None when the platform does not match the target, else a sort key (oldest first)."""
    if platform == "any":
        return (1, ())
    match = PLATFORMS[target].match(platform)
    if not match:
        return None
    groups = [g for g in match.groups() if g is not None]
    if target.startswith("linux-") and len(groups) == 1:
        return (0, LEGACY_MANYLINUX[groups[0]])
    return (0, tuple(int(g) for g in groups))


def python_rank(python_tag, abi_tag, cp):
    """None when the interpreter and ABI tags do not fit CPython cp (e.g. 314), else a sort key."""
    if python_tag == f"cp{cp}" and abi_tag == f"cp{cp}":
        return (0, 0)
    match = re.match(r"^cp3(\d+)$", python_tag)
    if match and abi_tag == "abi3" and 2 <= int(match.group(1)) <= cp - 300:
        return (1, -int(match.group(1)))
    if python_tag in ("py3", f"py{cp}") and abi_tag == "none":
        return (2, 0)
    return None


def pick(target, cp, files):
    best = None
    for item in files:
        name = item["filename"]
        if item["packagetype"] != "bdist_wheel" or not name.endswith(".whl"):
            continue
        parts = name[:-4].split("-")
        python_tags, abi_tags, platform_tags = parts[-3].split("."), parts[-2].split("."), parts[-1].split(".")
        for python_tag in python_tags:
            for abi_tag in abi_tags:
                rank_python = python_rank(python_tag, abi_tag, cp)
                if rank_python is None:
                    continue
                for platform in platform_tags:
                    rank_platform = platform_rank(target, platform)
                    if rank_platform is None:
                        continue
                    key = (rank_platform[0], rank_python, rank_platform[1], name)
                    if best is None or key < best[0]:
                        best = (key, item)
    return None if best is None else best[1]


def extract(path, site_packages):
    """Extracts a wheel: the .data/purelib and .data/platlib folders go to site-packages, the others are dropped."""
    with zipfile.ZipFile(path) as wheel:
        for entry in wheel.infolist():
            name = entry.filename
            if name.endswith("/"):
                continue
            parts = name.split("/")
            if parts[0].endswith(".data"):
                if len(parts) < 3 or parts[1] not in ("purelib", "platlib"):
                    continue
                parts = parts[2:]
            if any(p in ("", ".", "..") for p in parts) or os.path.isabs(name):
                raise SystemExit(f"unsafe path {name!r} in {path}")
            destination = os.path.join(site_packages, *parts)
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            with wheel.open(entry) as source, open(destination, "wb") as output:
                output.write(source.read())


def main(argv):
    if len(argv) < 6:
        raise SystemExit(__doc__)
    target, python_version, site_packages, lock_file = argv[1:5]
    if target not in PLATFORMS:
        raise SystemExit(f"unknown target {target}")
    major, minor = python_version.split(".")[:2]
    cp = int(major) * 100 + int(minor)
    downloads = os.path.join(os.path.dirname(os.path.abspath(lock_file)), "wheels")
    os.makedirs(downloads, exist_ok=True)
    os.makedirs(site_packages, exist_ok=True)
    lines = []
    for requirement in argv[5:]:
        name, separator, version = requirement.partition("==")
        if not separator or not version:
            raise SystemExit(f"{requirement}: an exact version (name==version) is required")
        release = json.loads(fetch(f"https://pypi.org/pypi/{name}/{version}/json"))
        item = pick(target, cp, release["urls"])
        if item is None:
            raise SystemExit(f"no wheel of {name} {version} for CPython {python_version} on {target}")
        path = os.path.join(downloads, item["filename"])
        expected = item["digests"]["sha256"]
        if not os.path.exists(path) or hashlib.sha256(open(path, "rb").read()).hexdigest() != expected:
            data = fetch(item["url"])
            actual = hashlib.sha256(data).hexdigest()
            if actual != expected:
                raise SystemExit(f"the SHA-256 of {item['filename']} is {actual}, expected {expected}")
            with open(path, "wb") as f:
                f.write(data)
        print(f"{item['filename']} {expected}")
        extract(path, site_packages)
        lines.append(f"{item['filename']} {expected}\n")
    with open(lock_file, "w", encoding="utf-8", newline="\n") as f:
        f.writelines(lines)


if __name__ == "__main__":
    main(sys.argv)
