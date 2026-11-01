#!/bin/sh
# 依次编译 Novelia 与 NoveliaLegacy。任一 scheme 失败则本脚本以非 0 退出。
# 用于共享源码改动后的日常检查，不替代 scripts/build_local_release.py 的发布构建。
set -eu
cd "$(dirname "$0")/.."
for scheme in Novelia NoveliaLegacy; do
  echo "Building $scheme"
  xcodebuild \
    -project NoveliaIOS.xcodeproj \
    -scheme "$scheme" \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO \
    build
done
