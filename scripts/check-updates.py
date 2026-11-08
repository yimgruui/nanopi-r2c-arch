#!/usr/bin/env python3
"""Bump the vendored ksmbd-tools package to the latest upstream version.

- ksmbd-tools: follow the AUR package version and its release tarball.

Prints a human-readable summary and writes changed=true|false + summary to
$GITHUB_OUTPUT when running in GitHub Actions.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KSMBD_PKGBUILD = os.path.join(ROOT, "packaging/ksmbd-tools/PKGBUILD")

KSMBD_TARBALL = "https://github.com/cifsd-team/ksmbd-tools/archive/refs/tags/{version}.tar.gz"
AUR_RPC = "https://aur.archlinux.org/rpc/v5/info?arg[]=ksmbd-tools"

TIMEOUT = 120


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "nanopi-r2c-update-check"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return response.read()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def replace_line(text, key, value):
    new_text, count = re.subn(
        rf"^{re.escape(key)}=.*$", f"{key}={value}", text, count=1, flags=re.MULTILINE
    )
    if count != 1:
        raise RuntimeError(f"missing {key}= in PKGBUILD")
    return new_text


def replace_sums(text, digest):
    new_text, count = re.subn(
        r"^sha256sums=\(.*\)$", f"sha256sums=('{digest}')", text, count=1, flags=re.MULTILINE
    )
    if count != 1:
        raise RuntimeError("missing sha256sums= in PKGBUILD")
    return new_text


def version_gt(candidate, current):
    """True when candidate is strictly newer than current (dpkg vercmp)."""
    try:
        return subprocess.run(
            ["dpkg", "--compare-versions", candidate, "gt", current]
        ).returncode == 0
    except FileNotFoundError:
        return candidate != current


def check_ksmbd(changes):
    payload = json.loads(fetch(AUR_RPC))
    entries = [item for item in payload.get("results", []) if item.get("Name") == "ksmbd-tools"]
    if not entries:
        raise RuntimeError("ksmbd-tools not found in the AUR RPC response")

    # Version looks like "3.5.7-1"; pkgver is the part before the last dash.
    latest = entries[0]["Version"].rsplit("-", 1)[0]

    text = read(KSMBD_PKGBUILD)
    match = re.search(r"^pkgver=(\S+)$", text, re.MULTILINE)
    if not match:
        raise RuntimeError("missing pkgver= in ksmbd-tools PKGBUILD")
    current = match.group(1)

    if latest == current:
        print(f"ksmbd-tools: up to date ({current})")
        return
    if not version_gt(latest, current):
        print(f"ksmbd-tools: AUR has {latest}, vendored {current} is newer; keeping it")
        return

    digest = sha256(fetch(KSMBD_TARBALL.format(version=latest)))
    text = replace_line(text, "pkgver", latest)
    text = replace_sums(text, digest)
    write(KSMBD_PKGBUILD, text)
    changes.append(f"ksmbd-tools {current} -> {latest}")


def main():
    changes = []

    for check in (check_ksmbd,):
        try:
            check(changes)
        except Exception as error:  # keep the other package check running
            print(f"warning: {check.__name__} failed: {error}", file=sys.stderr)

    changed = "true" if changes else "false"
    summary = "; ".join(changes) if changes else "packages up to date"

    print(f"changed={changed}: {summary}")

    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"changed={changed}\n")
            handle.write(f"summary={summary}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
