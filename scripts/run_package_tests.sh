#!/bin/sh
# 在 iOS 模拟器上运行 Swift 包测试（NoveliaIOSCoreTests、NoveliaEPUBTests）。
# 用法：scripts/run_package_tests.sh [模拟器名称或 UDID] [额外的 xcodebuild 参数...]
# 包以 iOS 17 为目标且依赖 UIKit，因此在模拟器上运行，而不是用 `swift test`。
# 两者并存时 xcodebuild 优先打开 NoveliaIOS.xcodeproj，所以从一个只链接包文件的
# 临时目录打开 Swift 包。
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
device="${1:-iPhone 18 Pro}"
[ "$#" -gt 0 ] && shift
case "$device" in
  *-*-*-*-*) destination="platform=iOS Simulator,id=$device" ;;
  *) destination="platform=iOS Simulator,name=$device" ;;
esac
work="$(mktemp -d "${TMPDIR:-/tmp}/novelia-package-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
for item in Package.swift Sources Tests iOSApp Vendor; do ln -s "$root/$item" "$work/$item"; done
cd "$work"
xcodebuild test -scheme NoveliaIOSPort -destination "$destination" "$@"
