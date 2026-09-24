#!/usr/bin/env python3
"""Exercise cold launch event ordering in isolated, invisible AppKit processes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]) if len(sys.argv) > 1 else Path((root / 'work/staged-app-path.txt').read_text().strip())
binary = app / 'Contents/MacOS/Orkhon Code'
for scenario in ['early', 'reopen', 'late', 'restore-race', 'session', 'finder', 'finder', 'finder']:
    with tempfile.TemporaryDirectory(prefix='orkhon-startup-') as scratch:
        directory = Path(scratch)
        for name in ['requested.swift', 'saved1.swift', 'saved2.swift']:
            (directory / name).write_text('let value = 42\n')
        archive = {'windows': [{'paths': [str(directory / name)]} for name in ['saved1.swift', 'saved2.swift']]}
        (directory / 'session.json').write_text(json.dumps(archive))
        env = dict(os.environ, ORKHON_TEST_DATA=scratch, ORKHON_SKIP_SETUP='1', ORKHON_STARTUP_SCENARIO=scenario)
        command = [str(binary), '--startup-tests']
        if scenario == 'finder':
            # Send the same Launch Services open-document event used by Finder,
            # cold-launching the isolated review bundle rather than changing defaults.
            command = ['/usr/bin/open', '-n', '-W', '-a', str(app),
                       '--env', f'ORKHON_TEST_DATA={scratch}', '--env', 'ORKHON_SKIP_SETUP=1',
                       '--env', 'ORKHON_STARTUP_SCENARIO=finder', str(directory / 'requested.swift'),
                       '--args', '--startup-tests']
        run = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
        result = json.loads((directory / 'result.json').read_text())
        if run.returncode or result['failures']:
            raise RuntimeError(f'{scenario}: {result}\n{run.stderr}')
        print(f'{scenario}: {len(result["checks"])} launch checks passed', flush=True)
