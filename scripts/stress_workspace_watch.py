#!/usr/bin/env python3
"""Stress the shipped event helper, using temporary local files only.

On Linux this covers inotify; on macOS it covers FSEvents. A filesystem event
is an invalidation, so the contract is eventual delivery per burst, not one
notification per write. The UI's scheduler independently limits render rate.
"""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

helper=Path(__file__).resolve().parent.parent/'Resources/workspace_watch.py'

def next_line(p,timeout=30):
    if not select.select([p.stdout],[],[],timeout)[0]:
        raise AssertionError('Watcher did not invalidate after a burst')
    value=p.stdout.readline().decode().strip()
    assert value in ('ready','change'), ('watcher stopped',p.poll(),p.stderr.read().decode())
    return value

def drain(p):
    count=0
    while select.select([p.stdout],[],[],0.5)[0]:
        assert p.stdout.readline(), 'Watcher exited';count+=1
    return count

with tempfile.TemporaryDirectory(prefix='watch-stress-') as temp:
    root=Path(temp)
    for i in range(100):
        folder=root/f'dir-{i}'/'nested';folder.mkdir(parents=True)
        for j in range(50): (folder/f'file-{j}.arbitrary').write_text('initial\n')
    started=time.monotonic()
    p=subprocess.Popen([sys.executable,'-u',str(helper),str(root)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
    try:
        assert next_line(p)=='ready'
        ready_ms=(time.monotonic()-started)*1000
        batches=[]
        for wave in range(3):
            drain(p);start=time.monotonic()
            for i in range(100):
                folder=root/f'dir-{i}'/'nested'
                for j in range(20):
                    file=folder/f'file-{j}.arbitrary';temporary=folder/f'replacement-{j}'
                    temporary.write_text(f'wave {wave}\n{i}:{j}\n');os.replace(temporary,file)
                extra=folder/f'new-{wave}';extra.mkdir();(extra/'no-extension').write_bytes(b'\x00\xff')
                extra.rename(folder/f'renamed-{wave}')
            assert next_line(p)=='change'
            batches.append({'writes':2200,'secondsToObservedEvent':time.monotonic()-start,'notifications':1+drain(p)})
        # No content reads/hashes or recurring event messages while quiescent.
        drain(p);start=time.monotonic()
        assert not select.select([p.stdout],[],[],3)[0], 'Unexpected idle stream traffic'
        p.stdin.close();p.wait(timeout=5)
        assert p.returncode==0
        # Repeated start/stop catches orphan processes and missed lease cleanup.
        for _ in range(10):
            child=subprocess.Popen([sys.executable,'-u',str(helper),str(root)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
            assert next_line(child)=='ready';child.stdin.close();child.wait(timeout=5);assert child.returncode==0
        print(json.dumps({'platform':sys.platform,'directories':201,'initialFiles':5000,'startupMs':ready_ms,'batches':batches,'idleSeconds':3,'cleanReconnects':10},indent=2))
    finally:
        if p.poll() is None:
            p.stdin.close();p.terminate();p.wait(timeout=5)
