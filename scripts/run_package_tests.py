#!/usr/bin/env python3
"""固定 Swift 包测试工作区与编译缓存，相同输入复用成功记录。"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('local_build_cache', ROOT / 'scripts/local_build_cache.py')
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


def main():
    arguments = sys.argv[1:]
    force = '--force-checks' in arguments
    fresh = '--fresh-build' in arguments
    arguments = [a for a in arguments if a not in {'--force-checks', '--fresh-build'}]
    device = arguments.pop(0) if arguments else 'iPhone 18 Pro'
    identity = cache.simulator_identity(device)
    directory = cache.cache_directory(ROOT)
    if fresh:
        directory = Path(tempfile.mkdtemp(prefix='novelia-fresh-tests-', dir='/private/tmp'))
    # 独立运行和发布脚本调用使用同一个入口、锁和成功记录。
    with cache.file_lock(directory / 'package.lock'):
        workspace = directory / 'package-workspace'
        workspace.mkdir(parents=True, exist_ok=True)
        for name in ['Package.swift', 'Sources', 'Tests', 'iOSApp']:
            link = workspace / name
            if not link.is_symlink():
                link.symlink_to(ROOT / name)
            elif link.resolve() != (ROOT / name).resolve():
                raise RuntimeError(f'Unexpected cached workspace link: {name}')
        # Xcode 27.2 对经符号链接访问的本地 C 包生成错误的测试产品依赖；
        # 使用内容相同的实际副本，仍由源码摘要保证验证对象与项目一致。
        vendor = workspace / 'Vendor'
        if vendor.is_symlink():
            vendor.unlink()
        if vendor.exists():
            shutil.rmtree(vendor)
        shutil.copytree(ROOT / 'Vendor', vendor, ignore=shutil.ignore_patterns('.swiftpm', '.build'))
        # 使用与 App 相同的已锁定依赖；只复制，不让 SwiftPM 重写项目原文件。
        pinned = ROOT / 'NoveliaIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        target = workspace / 'Package.resolved'
        if not target.exists() or target.read_bytes() != pinned.read_bytes():
            shutil.copyfile(pinned, target)
        destination = f"platform=iOS Simulator,id={identity['udid']}"
        command = ['xcodebuild', 'test', '-scheme', 'NoveliaIOSPort', '-destination', destination,
                   '-derivedDataPath', str(directory / 'package-derived'), '-disableAutomaticPackageResolution',
                   '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '120']
        if '-derivedDataPath' in arguments:
            index = command.index('-derivedDataPath')
            del command[index:index + 2]
        command.extend(arguments)
        # 显式请求独立结果文件时必须实际执行，不能只返回缓存日志。
        force = force or bool(os.environ.get('SCAN_EPUB')) or any(a in arguments for a in ['-resultBundlePath', '-resultStreamPath'])
        selected_derived = directory / 'package-derived'
        if '-derivedDataPath' in arguments:
            value = arguments[arguments.index('-derivedDataPath') + 1]
            selected_derived = (workspace / value).resolve()
        checkout_directory = selected_derived / 'SourcePackages/checkouts'
        if '-clonedSourcePackagesDirPath' in arguments:
            value = arguments[arguments.index('-clonedSourcePackagesDirPath') + 1]
            checkout_directory = (workspace / value).resolve() / 'checkouts'
        checks = cache.Checks(ROOT, directory / 'checks/package',
                              {'toolchain': cache.toolchain_identity(), 'simulator': identity}, force=force or fresh,
                              validator=lambda: cache.checkouts_ready(checkout_directory, pinned))
        log = directory / 'package-last.log'
        # 独立包工作区避免 xcodebuild 优先打开 App 工程；参数通过位置参数传递，路径不插入 shell 代码。
        command = ['/bin/sh', '-c', 'cd "$1" && shift && exec "$@"', 'novelia-package', str(workspace), *command]
        try:
            checks.run(command, log)
        finally:
            if log.exists():
                sys.stdout.write(log.read_text(errors='replace'))
        (directory / 'package-last-result.json').write_text(json.dumps(checks.results))
    if fresh:
        shutil.rmtree(directory)


if __name__ == '__main__':
    main()
