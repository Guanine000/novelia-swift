#!/bin/sh
# Lay out a local EPUB with the reader's default settings and report justified-text
# gaps and lines drawn wider than laid out, with and without the engine workaround.
# Usage: scripts/scan_epub_layout.sh /path/to/book.epub [simulator name or UDID]
# The book is read in place and never copied into the repository.
set -eu
[ "$#" -ge 1 ] || { echo "usage: $0 book.epub [simulator]" >&2; exit 64; }
book="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[ -f "$book" ] || { echo "not a file: $1" >&2; exit 66; }
cd "$(dirname "$0")/.."
TEST_RUNNER_SCAN_EPUB="$book" scripts/run_package_tests.sh "${2:-iPhone 18 Pro}" \
  -only-testing:NoveliaEPUBTests/EPUBLayoutTests/testScanExternalBook 2>&1 \
  | grep -E '^SCAN_|error:|\*\* TEST' | sed 's/^SCAN_EXAMPLE//' || true
