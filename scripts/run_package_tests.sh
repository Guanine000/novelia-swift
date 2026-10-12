#!/bin/sh
# Run the Swift package tests (NoveliaIOSCoreTests, NoveliaEPUBTests) on an iOS simulator.
# Usage: scripts/run_package_tests.sh [simulator name or UDID] [extra xcodebuild arguments...]
# The package targets iOS 17 and uses UIKit, so tests run on a simulator rather than `swift test`.
# xcodebuild prefers NoveliaIOS.xcodeproj when both exist, so the package is opened from a
# temporary directory that links only the package files.
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
for item in Package.swift Sources Tests iOSApp; do ln -s "$root/$item" "$work/$item"; done
cd "$work"
xcodebuild test -scheme NoveliaIOSPort -destination "$destination" "$@"
