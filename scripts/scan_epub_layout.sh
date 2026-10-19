#!/bin/sh
# 用阅读器默认设置排版本地 EPUB，分别在启用与不启用引擎规避方案时，
# 报告两端对齐产生的间隙，以及绘制宽度超出排版宽度的行。
# 用法：scripts/scan_epub_layout.sh /path/to/book.epub [模拟器名称或 UDID]
# 书籍在原位置读取，绝不复制到仓库中。
set -eu
[ "$#" -ge 1 ] || { echo "usage: $0 book.epub [simulator]" >&2; exit 64; }
book="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[ -f "$book" ] || { echo "not a file: $1" >&2; exit 66; }
cd "$(dirname "$0")/.."
TEST_RUNNER_SCAN_EPUB="$book" scripts/run_package_tests.sh "${2:-iPhone 18 Pro}" \
  -only-testing:NoveliaEPUBTests/EPUBLayoutTests/testScanExternalBook 2>&1 \
  | grep -E '^SCAN_|error:|\*\* TEST' | sed 's/^SCAN_EXAMPLE//' || true
