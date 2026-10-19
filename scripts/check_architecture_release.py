#!/usr/bin/env python3
"""确认 Debug 架构验证代码没有进入 Release 可执行文件。"""
from pathlib import Path
import argparse
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('executable', type=Path)
args = parser.parse_args()
data = args.executable.read_bytes()
for marker in [b'-architectureValidation', b'-resetArchitectureValidation', b'-architectureReadium', b'-architecturePagination',
               b'-architectureFailFirstSearch', b'-seedPerformanceLibrary', b'-performanceLibraryCount', b'-performanceLargeTXT', b'-architectureTXT', b'ArchitectureNetworkTrap', b'architecture-user']:
    if marker in data:
        raise SystemExit('Unexpected validation runtime marker: ' + marker.decode())
symbols = subprocess.check_output(['nm', '-gj', str(args.executable)], text=True)
for marker in ['ArchitectureFixtureBackend', 'FixtureTokenStore', 'ArchitectureNetworkTrap', 'architectureValidation']:
    if marker in symbols:
        raise SystemExit('Unexpected validation runtime symbol: ' + marker)
# 即使 #if DEBUG 移除了全部声明，编译器的源文件表仍可能保留
# ArchitectureFixtureBackend.swift。因此检查符号与数据，而非文件名。
print('Release excludes validation backend, in-memory credentials, network trap and launch argument')
