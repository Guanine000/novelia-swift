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


if __name__ == "__main__":
    failures = list(violations())
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit(1)
    print("Architecture dependency boundaries passed")
