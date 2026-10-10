#!/usr/bin/env python3
"""Reject developer home paths and credential signatures in a distribution IPA."""
import argparse
import plistlib
import re
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("ipa")
args = parser.parse_args()
patterns = {
    "developer home path": rb"(?:/Users/|/home/)[A-Za-z0-9_.-]+/",
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "GitHub token": rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})",
    "AWS access key": rb"AKIA[0-9A-Z]{16}",
    "JWT": rb"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}",
}
failures = []
with zipfile.ZipFile(args.ipa) as archive:
    for name in archive.namelist():
        if name.endswith("/"):
            continue
        data = archive.read(name)
        # Inspect both raw binary strings and decoded binary plist values.
        candidates = [data]
        if name.endswith(".plist"):
            candidates.append(repr(plistlib.loads(data)).encode())
        for label, pattern in patterns.items():
            if any(re.search(pattern, item) for item in candidates):
                failures.append(f"{name}: {label}")
if failures:
    raise SystemExit("Release privacy check failed (values redacted):\n" + "\n".join(failures))
print("Release privacy check passed: no developer home paths or checked credential signatures")
