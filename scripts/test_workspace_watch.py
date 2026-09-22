#!/usr/bin/env python3
"""Exercise the real helper on Linux/inotify or macOS/FSEvents, without SSH."""
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

helper = Path(__file__).resolve().parent.parent / 'Resources/workspace_watch.py'

def line(process, timeout=20):
    # Unbuffered binary pipe; select must not race a BufferedReader's hidden data.
    if not select.select([process.stdout], [], [], timeout)[0]:
        raise AssertionError('No filesystem event before deadline')
    return process.stdout.readline().decode().strip()

with tempfile.TemporaryDirectory(prefix='orkhon-code-test-') as temp:
    root = Path(temp)
    nested = root / 'a' / 'deep'
    nested.mkdir(parents=True)
    file = nested / 'no-extension'
    file.write_text('first')
    outside = root.parent / ('outside-' + root.name)
    outside.mkdir()
    (root / 'cycle').symlink_to(root, target_is_directory=True)
    (root / 'outside').symlink_to(outside, target_is_directory=True)
    process = subprocess.Popen([sys.executable, '-u', str(helper), str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    try:
        assert line(process) == 'ready', process.stderr.read().decode()
        def drain():
            while select.select([process.stdout], [], [], 0.3)[0]:
                assert process.stdout.readline() != b'', 'Watcher exited unexpectedly'
        def changed(name, action):
            drain();action();assert line(process)=='change', name
            print('PASS:', name)
        changed('deep extensionless edits', lambda:file.write_text('second'))
        changed('arbitrary binary extension', lambda:(nested/'asset.weird').write_bytes(b'\0\1\2'))
        changed('atomic replacement', lambda:((nested/'temp').write_text('third'), os.replace(nested/'temp', file)))
        changed('directory creation', lambda:(nested/'new').mkdir())
        changed('file inside newly created directory', lambda:(nested/'new'/'late').write_text('late'))
        changed('directory rename', lambda:(nested/'new').rename(nested/'moved'))
        changed('edit after directory rename', lambda:(nested/'moved'/'late').write_text('updated'))
        changed('deletion', lambda:file.unlink())
        drain();(outside/'ignored').write_text('outside workspace')
        assert not select.select([process.stdout], [], [], 0.5)[0], 'Followed an external directory symlink'
        print('PASS: directory symlinks do not widen workspace or loop')
        drain();(nested/'asset.weird').read_bytes()
        assert not select.select([process.stdout], [], [], 0.5)[0], 'Read triggered a change loop'
        print('PASS: preview reads do not trigger updates')
        process.stdin.close();process.wait(timeout=5)
        assert process.returncode==0, process.stderr.read().decode()
        print('PASS: stdin EOF releases idle watcher')
    finally:
        if process.poll() is None:
            process.stdin.close();process.terminate();process.wait(timeout=5)
        import shutil
        shutil.rmtree(outside)
