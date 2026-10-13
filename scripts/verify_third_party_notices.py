#!/usr/bin/env python3
"""Check the distributed Swift Package notices against Package.resolved."""

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOLVED = ROOT / "NoveliaIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
NOTICES = ROOT / "iOSApp/Resources/ThirdPartyLicenses"
# identity -> (notice name, license, license file in the SwiftPM checkout)
PACKAGES = {
    "swiftsoup": ("SwiftSoup", "MIT", "LICENSE"),
    "yueducoretext": ("YueduCoreText", "MPL-2.0", "LICENSE"),
    "zipfoundation": ("ZIPFoundation", "MIT", "LICENSE"),
    "swift-toolkit": ("swift-toolkit", "BSD-3-Clause", "LICENSE"),
    "cryptoswift": ("CryptoSwift", "CryptoSwift License (zlib-style, attribution)", "LICENSE"),
    "differencekit": ("DifferenceKit", "Apache-2.0", "LICENSE"),
    "fuzi": ("Fuzi", "MIT", "LICENSE"),
    "gcdwebserver": ("GCDWebServer", "BSD-3-Clause", "LICENSE"),
    "sqlite.swift": ("SQLite.swift", "MIT", "LICENSE.txt"),
    "zip": ("Zip", "MIT", "LICENSE"),
}
READIUM_FONTS = "Sources/Navigator/EPUB/Assets/Static/readium-css/fonts"
# Bundled by swift-toolkit's resource bundles: notice file -> license file in the checkout
READIUM_ASSET_NOTICES = {
    "ReadiumCSS-AccessibleDfA-LICENSE.txt": f"{READIUM_FONTS}/LICENSE-AccessibleDfa",
    "ReadiumCSS-iAWriterDuospace-LICENSE.txt": f"{READIUM_FONTS}/LICENSE-IaWriterDuospace.md",
}
READIUM_SCRIPTS_LOCK = "Sources/Navigator/EPUB/Scripts/pnpm-lock.yaml"


def checkout_name(pin: dict) -> str:
    """SwiftPM checks a package out under its repository name."""
    return pin["location"].rstrip("/").removesuffix(".git").rsplit("/", 1)[-1]


def production_scripts(lockfile: Path) -> list[str]:
    """name@version of every non-dev package in the navigator scripts' pnpm lockfile."""
    text = lockfile.read_text()
    packages = text[text.index("\npackages:"):]
    result = []
    for entry in re.split(r"\n  (?=/)", packages)[1:]:
        head = entry.split("\n", 1)[0].strip().rstrip(":")
        if re.search(r"\n    dev: false", entry):
            name, version = re.match(r"/(.+)@([^@]+)$", head).groups()
            result.append(f"{name}@{version}")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-packages", type=Path, help="SwiftPM checkouts after Xcode build")
    args = parser.parse_args()

    pins = {pin["identity"]: pin for pin in json.loads(RESOLVED.read_text())["pins"]}
    assert set(pins) == set(PACKAGES), f"Package.resolved identities changed: {set(pins) ^ set(PACKAGES)}"
    index = (NOTICES / "INDEX.md").read_text()
    assert "Unicode License v3" in index
    assert "Marcin Krzyzanowski" in index, "CryptoSwift attribution is required in the documentation"
    for identity, (name, license_id, checkout_license) in PACKAGES.items():
        pin = pins[identity]
        version = pin["state"]["version"]
        source_url = pin["location"].removesuffix(".git")
        filename = f"{name}-LICENSE.txt"
        license_file = NOTICES / filename
        assert license_file.is_file() and license_file.stat().st_size > 0, filename
        expected_row = f"| {name} | {version} | {license_id} | {source_url} | [{filename}]({filename}) |"
        assert expected_row in index, f"Missing or stale index row: {name} {version}"
        if args.source_packages:
            checkout = args.source_packages / checkout_name(pin)
            original = checkout / checkout_license
            assert original.is_file(), f"Missing checkout license: {original}"
            assert license_file.read_bytes() == original.read_bytes(), f"Copied license differs: {name}"
            original_notice = checkout / "NOTICE"
            if original_notice.is_file():
                bundled_notice = NOTICES / f"{name}-NOTICE.txt"
                assert bundled_notice.is_file(), f"Missing NOTICE: {name}"
                assert bundled_notice.read_bytes() == original_notice.read_bytes(), f"NOTICE differs: {name}"
    for notice in list(READIUM_ASSET_NOTICES) + ["OpenDyslexic-LICENSE.txt", "Readium-JavaScript-NOTICES.txt"]:
        assert (NOTICES / notice).is_file(), f"Missing Readium asset notice: {notice}"
        assert f"]({notice})" in index, f"Readium asset notice not listed in INDEX.md: {notice}"
    if args.source_packages:
        toolkit = args.source_packages / checkout_name(pins["swift-toolkit"])
        for notice, original in READIUM_ASSET_NOTICES.items():
            assert (NOTICES / notice).read_bytes() == (toolkit / original).read_bytes(), f"Font license differs: {notice}"
        scripts = (NOTICES / "Readium-JavaScript-NOTICES.txt").read_text()
        for package in production_scripts(toolkit / READIUM_SCRIPTS_LOCK):
            assert f"\n{package} — " in scripts, f"Bundled script package missing from notices: {package}"
    yuedu_pin = pins["yueducoretext"]
    assert yuedu_pin["state"]["revision"] in index, "Exact YueduCoreText source revision is missing"
    assert (NOTICES / "YueduCoreText-NOTICE.txt").is_file()
    print(f"Verified {len(pins)} Swift Package licenses, the YueduCoreText NOTICE and Readium font/script notices")


if __name__ == "__main__":
    main()
