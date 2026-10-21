#!/usr/bin/env python3
"""核对随包分发的 Swift Package 许可声明与 Package.resolved 是否一致。"""

import argparse
import json
import struct
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOLVED = ROOT / "NoveliaIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
NOTICES = ROOT / "iOSApp/Resources/ThirdPartyLicenses"
# 依赖标识 -> (声明名称, 许可证, SwiftPM 检出目录中的许可证文件)
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
# 由 swift-toolkit 资源包附带：声明文件 -> 检出目录中的许可证文件
READIUM_ASSET_NOTICES = {
    "ReadiumCSS-AccessibleDfA-LICENSE.txt": f"{READIUM_FONTS}/LICENSE-AccessibleDfa",
    "ReadiumCSS-iAWriterDuospace-LICENSE.txt": f"{READIUM_FONTS}/LICENSE-IaWriterDuospace.md",
}
READIUM_SCRIPTS_LOCK = "Sources/Navigator/EPUB/Scripts/pnpm-lock.yaml"
OPENDYSLEXIC_FONTS = ["Sources/Navigator/EPUB/Assets/Static/fonts", "Sources/Streamer/Assets/fonts"]


def font_names(path: Path) -> dict[int, str]:
    """读取 OpenType 字体中 Windows 平台的 name 记录（版权 = 0，许可 = 13）。"""
    data = path.read_bytes()
    tables = struct.unpack(">H", data[4:6])[0]
    base = next(offset for tag, _, offset, _ in
                (struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i]) for i in range(tables)) if tag == b"name")
    _, count, strings = struct.unpack(">HHH", data[base:base + 6])
    names = {}
    for i in range(count):
        platform, _, _, name_id, length, offset = struct.unpack(">HHHHHH", data[base + 6 + 12 * i:base + 18 + 12 * i])
        if platform == 3:
            start = base + strings + offset
            names[name_id] = data[start:start + length].decode("utf-16-be")
    return names


def checkout_name(pin: dict) -> str:
    """SwiftPM 以仓库名作为依赖的检出目录名。"""
    return pin["location"].rstrip("/").removesuffix(".git").rsplit("/", 1)[-1]


def production_scripts(lockfile: Path) -> list[str]:
    """导航器脚本 pnpm 锁定文件中全部非开发依赖的 name@version。"""
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
    minizip = NOTICES / "Zip-MiniZip-NOTICE.txt"
    assert minizip.is_file() and "](Zip-MiniZip-NOTICE.txt)" in index, "Missing nested Zip license"
    nested_notice = minizip.read_text()
    for required in ["Copyright (C) 1990-2000 Info-ZIP", "2009-Jan-02", "Gilles Vollant", "Terry Thorsen",
                     "Redistributions in binary form", "zlib", "Jean-loup Gailly", "Mark Adler"]:
        assert required in nested_notice, f"Incomplete nested Zip notice: {required}"
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
        dyslexic = (NOTICES / "OpenDyslexic-LICENSE.txt").read_text()
        fonts = [font for folder in OPENDYSLEXIC_FONTS for font in sorted((toolkit / folder).glob("OpenDyslexic*"))]
        assert fonts, "OpenDyslexic fonts not found in swift-toolkit"
        for font in fonts:
            for name_id in (0, 13):
                assert font_names(font)[name_id] in dyslexic, f"OpenDyslexic notice not quoted verbatim: {font.name} name {name_id}"
        scripts = (NOTICES / "Readium-JavaScript-NOTICES.txt").read_text()
        for package in production_scripts(toolkit / READIUM_SCRIPTS_LOCK):
            assert f"\n{package} — " in scripts, f"Bundled script package missing from notices: {package}"
    yuedu_pin = pins["yueducoretext"]
    assert yuedu_pin["state"]["revision"] in index, "Exact YueduCoreText source revision is missing"
    assert (NOTICES / "YueduCoreText-NOTICE.txt").is_file()
    print(f"Verified {len(pins)} Swift Package licenses, the YueduCoreText NOTICE and Readium font/script notices")


if __name__ == "__main__":
    main()
