#!/usr/bin/env python3
"""本机编译缓存与精确输入的成功检查记录；不包含可分发产物。"""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import time

SCHEMA = 1


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True).encode()).hexdigest()


def cache_directory(root):
    # 每个 checkout 单独使用，防止公私 worktree 的源码、依赖和构建配置相互覆盖。
    return Path('/private/tmp') / f'novelia-build-cache-{os.getuid()}' / digest(str(root.resolve()))[:20]


@contextlib.contextmanager
def file_lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def source_digest(root):
    names = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
    files = {}
    for name in sorted(set(filter(None, names))):
        path = root / name
        if path.is_symlink():
            raise RuntimeError(f'Source symlink requires review: {name}')
        files[name] = [hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mode & 0o777] if path.is_file() else None
    return digest(files)


def environment_digest():
    # 环境变量只存摘要，不写入任何值或凭据。排除不影响构建的 shell/显示状态和本工具控制项。
    ignored = {'_', 'PWD', 'OLDPWD', 'SHLVL', 'TERM', 'COLUMNS', 'LINES', 'NOVELIA_FORCE_CHECKS', 'CODEX_TOOL_CALL_ID', 'CODEX_THREAD_ID', 'CODEX_SESSION_ID',
               'CODEX_APP_TOOLS_PIPE_PATH', 'CODEX_TASK_WORKSPACE_VERIFYING_IDENTITY',
               'BROWSER_USE_ACCESS_VERIFYING_IDENTITY', 'NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S',
               'CODEX_SAGE_BACKFILL_TRACKER_TAB_REUSE'}
    return digest({k: v for k, v in os.environ.items() if k not in ignored})


def toolchain_identity():
    commands = [['xcodebuild', '-version'], ['xcrun', 'swiftc', '--version'],
                ['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'],
                ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version']]
    return digest([subprocess.check_output(c, text=True).strip() for c in commands] + [platform.platform(), platform.python_version()])


def simulator_identity(device):
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], text=True))['devices']
    matches = [(runtime, entry['udid']) for runtime, entries in devices.items() for entry in entries
               if entry['udid'] == device or entry['name'] == device]
    if len(matches) != 1:
        raise RuntimeError('Simulator must resolve to exactly one available device; use its UDID')
    runtime, udid = matches[0]
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json'], text=True))['runtimes']
    info = next(r for r in runtimes if r['identifier'] == runtime)
    return {'udid': udid, 'runtime': runtime, 'version': info.get('version'), 'build': info.get('buildversion')}


def checkouts_ready(directory, pin_file):
    """缺失或旧版本交给 SwiftPM 更新；改脏的依赖拒绝复用/构建，不能用缓存掩盖本地修改。"""
    ready = True
    for pin in json.loads(pin_file.read_text())["pins"]:
        name = pin["location"].rstrip("/").removesuffix(".git").rsplit("/", 1)[-1]
        checkout = directory / name
        if not checkout.exists():
            ready = False
            continue
        if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all'], cwd=checkout).strip():
            raise RuntimeError(f'Dependency checkout is modified: {name}; use --fresh-build or inspect it')
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=checkout, text=True).strip()
        ready = ready and head == pin['state']['revision']
    return ready


class Checks:
    def __init__(self, root, directory, identity, force=False, validator=None):
        self.root = root
        self.directory = directory
        self.identity = identity
        self.source = source_digest(root)
        self.force = force
        self.results = []
        self.validator = validator

    def run(self, command, log):
        """仅复用成功且日志摘要正确的同输入检查；失败或执行中源码变化不会留下成功记录。"""
        started = time.monotonic()
        key = digest({'schema': SCHEMA, 'source': self.source, 'identity': self.identity,
                      'command': [str(x) for x in command], 'environment': environment_digest()})
        with file_lock(self.directory / (key + ".lock")):
            self._run(command, log, key, started)

    def _run(self, command, log, key, started):
        entry = self.directory / key
        receipt = entry / 'success.json'
        cached_log = entry / 'output.log'
        if source_digest(self.root) != self.source:
            raise RuntimeError('Source changed before validation; restart with a stable snapshot')
        dependencies_ready = self.validator() if self.validator else True
        if not self.force and dependencies_ready:
            try:
                data = json.loads(receipt.read_text())
                output = cached_log.read_bytes()
                if (data['key'] == key and data['sha256'] == hashlib.sha256(output).hexdigest()
                        and 0 <= time.time() - data['completedAt'] <= 24 * 60 * 60):
                    log.write_bytes(b'Validation cache: HIT; exact source, environment and command matched\n' + output)
                    self.results.append({'check': log.name, 'reused': True, 'key': key,
                                         'seconds': round(time.monotonic() - started, 3)})
                    print(f'REUSED {log.name}', flush=True)
                    return
            except (OSError, ValueError, KeyError, TypeError):
                pass
        entry.mkdir(parents=True, exist_ok=True)
        receipt.unlink(missing_ok=True)
        print(f'RUN {log.name}', flush=True)
        with log.open('wb') as stream:
            result = subprocess.run(command, cwd=self.root, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'Check failed; see {log}')
        if source_digest(self.root) != self.source:
            raise RuntimeError('Source changed during validation; result cannot be reused')
        if self.validator and not self.validator():
            raise RuntimeError('Dependency checkouts do not match pinned revisions after validation')
        shutil.copyfile(log, cached_log)
        data = {'key': key, 'sha256': hashlib.sha256(cached_log.read_bytes()).hexdigest(), 'completedAt': time.time()}
        temporary = entry / 'success.tmp'
        temporary.write_text(json.dumps(data))
        temporary.replace(receipt)
        self.results.append({'check': log.name, 'reused': False, 'key': key,
                             'seconds': round(time.monotonic() - started, 3)})
