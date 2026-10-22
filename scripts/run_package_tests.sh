#!/bin/sh
# 固定的独立包工作区与编译缓存；参数：[模拟器名称/UDID] [--force-checks] [--fresh-build] [xcodebuild 参数...]
# 相同源码、工具链、模拟器运行时和命令的成功检查可复用；失败不缓存。
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 -I "$root/scripts/run_package_tests.py" "$@"
