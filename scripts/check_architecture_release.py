#!/usr/bin/env python3
"""Confirm that Debug architecture validation is not part of a Release executable."""
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
# Compiler source-file tables may retain ArchitectureFixtureBackend.swift even
# when #if DEBUG removes every declaration. Check symbols and data, not filenames.
print('Release excludes validation backend, in-memory credentials, network trap and launch argument')
