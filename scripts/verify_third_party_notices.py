#!/usr/bin/env python3
"""Check the distributed Swift Package notices against Package.resolved."""

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOLVED = ROOT / "NoveliaIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
NOTICES = ROOT / "iOSApp/Resources/ThirdPartyLicenses"
PACKAGES = {
    "swiftsoup": ("SwiftSoup", "MIT"),
    "yueducoretext": ("YueduCoreText", "MPL-2.0"),
    "zipfoundation": ("ZIPFoundation", "MIT"),
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-packages", type=Path, help="SwiftPM checkouts after Xcode build")
    args = parser.parse_args()

    pins = {pin["identity"]: pin for pin in json.loads(RESOLVED.read_text())["pins"]}
    assert set(pins) == set(PACKAGES), f"Package.resolved identities changed: {set(pins) ^ set(PACKAGES)}"
    index = (NOTICES / "INDEX.md").read_text()
    assert "Unicode License v3" in index
    for identity, (name, license_id) in PACKAGES.items():
        pin = pins[identity]
        version = pin["state"]["version"]
        source_url = pin["location"].removesuffix(".git")
        filename = f"{name}-LICENSE.txt"
        license_file = NOTICES / filename
        assert license_file.is_file() and license_file.stat().st_size > 0, filename
        expected_row = f"| {name} | {version} | {license_id} | {source_url} | [{filename}]({filename}) |"
        assert expected_row in index, f"Missing or stale index row: {name} {version}"
        if args.source_packages:
            checkout = args.source_packages / name
            original = checkout / "LICENSE"
            assert original.is_file(), f"Missing checkout license: {original}"
            assert license_file.read_bytes() == original.read_bytes(), f"Copied license differs: {name}"
            original_notice = checkout / "NOTICE"
            if original_notice.is_file():
                bundled_notice = NOTICES / f"{name}-NOTICE.txt"
                assert bundled_notice.is_file(), f"Missing NOTICE: {name}"
                assert bundled_notice.read_bytes() == original_notice.read_bytes(), f"NOTICE differs: {name}"
    yuedu_pin = pins["yueducoretext"]
    assert yuedu_pin["state"]["revision"] in index, "Exact YueduCoreText source revision is missing"
    assert (NOTICES / "YueduCoreText-NOTICE.txt").is_file()
    print(f"Verified {len(pins)} Swift Package licenses and the YueduCoreText NOTICE")


if __name__ == "__main__":
    main()
