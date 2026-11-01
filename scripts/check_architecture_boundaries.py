#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""检查被禁止的源码依赖，不构建项目，也不访问用户数据。"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def violations(root=ROOT):
    rules = [
        ("Sources/NoveliaIOSCore/Domain", r"\b(?:SwiftUI|UIKit|AppServices|NoveliaAPIClient|ForumAPIClient|WebDAVSyncStore)\b",
         "Domain must not depend on UI, composition or concrete API clients"),
        ("Sources/NoveliaIOSCore/Infrastructure", r"\b(?:SwiftUI|AppServices|RootView)\b",
         "API infrastructure must not depend on UI or App composition"),
        ("iOSApp/Features", r"\b(?:NoveliaAPIClient|ForumAPIClient)\b",
         "Features must consume Domain service contracts"),
        ("iOSApp/Features/Reader", r"\b(?:WebDAVSyncStore|ReadingStatisticsStore)\b",
         "Readers must use progress and activity contracts"),
    ]
    for folder, pattern, reason in rules:
        for path in sorted((root / folder).rglob("*.swift")):
            # 忽略注释与字符串字面量，同时保留行号。这只是范围有限的回归守卫，
            # 不是 Swift 解析器，也不等同于编译器的模块边界。
            source = re.sub(r'/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"',
                            lambda match: "\n" * match[0].count("\n"), path.read_text())
            for match in re.finditer(pattern, source):
                line = source.count("\n", 0, match.start()) + 1
                yield f"{path.relative_to(root)}:{line}: {reason}: {match[0]}"


def target_membership_violations(root=ROOT):
    """主目标保持 iOS 17 与 YueduCoreText；iOS 15 目标不编译原生分页，也不链接 Yuedu / libmobi。"""
    text = (root / "NoveliaIOS.xcodeproj/project.pbxproj").read_text()
    def phase(identifier):
        match = re.search(rf"(?m)^\t\t{identifier} /\* [^*]+ \*/ = \{{.*?\n\t\t\}};", text, re.S)
        if not match:
            return f"missing build phase {identifier}"
        return match.group(0)
    main_sources = phase("A20000000000000000000001")
    legacy_sources = phase("A15E00000000000000000001")
    main_frameworks = phase("C10000000000000000000001")
    legacy_frameworks = phase("C15E00000000000000000001")
    if isinstance(main_sources, str) and main_sources.startswith("missing"):
        yield main_sources
        return
    def listed(phase_text):
        files = re.search(r"files = \((.*?)\);", phase_text, re.S)
        return re.findall(r"/\* ([^*]+) \*/", files.group(1)) if files else []
    main_names = listed(main_sources)
    legacy_names = listed(legacy_sources)
    excluded_sources = {
        "EPUBLayoutCoordinator.swift in Sources",
        "EPUBPageBook.swift in Sources",
        "EPUBPagerView.swift in Sources",
        "EPUBReaderModel.swift in Sources",
        "KindleEPUBConverter.swift in Sources",
        "KindleCSSMediaFlattener.swift in Sources",
        "KindleMOBI6Normalizer.swift in Sources",
    }
    only_main = [name for name in main_names if name not in set(legacy_names)]
    unexpected = [name for name in only_main if name not in excluded_sources]
    if unexpected:
        yield "NoveliaLegacy sources missing " + ", ".join(unexpected)
    still_compiled = [name for name in excluded_sources if name in set(legacy_names)]
    if still_compiled:
        yield "NoveliaLegacy still compiles " + ", ".join(sorted(still_compiled))
    only_legacy = [name for name in legacy_names if name not in set(main_names)]
    if only_legacy:
        yield "NoveliaLegacy sources not in Novelia: " + ", ".join(only_legacy)
    main_fw = set(listed(main_frameworks))
    legacy_fw = set(listed(legacy_frameworks))
    if main_fw != legacy_fw | {"YueduCoreText in Frameworks", "CLibMobi in Frameworks"}:
        yield f"Frameworks diverged: main-only {sorted(main_fw - legacy_fw)}, legacy-only {sorted(legacy_fw - main_fw)}"
    main_resources = phase("A20000000000000000000002")
    legacy_resources = phase("A15E00000000000000000002")
    if set(listed(main_resources)) != set(listed(legacy_resources)):
        yield "Resources phases differ between Novelia and NoveliaLegacy"
    if "NOVELIA_READIUM_ONLY" not in text:
        yield "NoveliaLegacy is missing NOVELIA_READIUM_ONLY"
    main_configs = re.search(r"F20000000000000000000003 /\* Debug \*/ = \{.*?\n\t\t\};.*?F20000000000000000000004 /\* Release \*/ = \{.*?\n\t\t\};", text, re.S)
    if not main_configs or main_configs.group(0).count("IPHONEOS_DEPLOYMENT_TARGET = 17.0;") != 2 or "NOVELIA_READIUM_ONLY" in main_configs.group(0):
        yield "Novelia target deployment or compilation conditions changed"
    legacy_configs = re.search(r"F15E00000000000000000001 /\* Debug \*/ = \{.*?\n\t\t\};.*?F15E00000000000000000002 /\* Release \*/ = \{.*?\n\t\t\};", text, re.S)
    if not legacy_configs or legacy_configs.group(0).count("IPHONEOS_DEPLOYMENT_TARGET = 15.0;") != 2 or legacy_configs.group(0).count("NOVELIA_READIUM_ONLY") != 2:
        yield "NoveliaLegacy deployment target or Readium-only flag is wrong"
    if "PRODUCT_BUNDLE_IDENTIFIER = cc.novelia.ios.port.ios15;" not in text:
        yield "NoveliaLegacy bundle identifier changed"
    if len(re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = cc\.novelia\.ios\.port;", text)) != 2:
        yield "Novelia bundle identifier changed"


if __name__ == "__main__":
    failures = list(violations()) + list(target_membership_violations())
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit(1)
    print("Architecture dependency boundaries passed")
