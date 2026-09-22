#!/usr/bin/env python3
"""Run native integration checks with isolated data and a loopback web fixture."""
import functools
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]) if len(sys.argv) > 1 else Path((root / 'work/staged-app-path.txt').read_text().strip())
binary = app / 'Contents/MacOS/Orkhon Code'
reports = Path(os.environ.get('ORKHON_TEST_REPORT_DIR', str(root / 'work')))
reports.mkdir(parents=True, exist_ok=True)
class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

with tempfile.TemporaryDirectory(prefix='orkhon-integration-') as scratch:
    directory = Path(scratch)
    (directory / 'script.js').write_text('window.networkAsset=73;')
    handler = functools.partial(QuietHandler, directory=scratch)
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for flag, name in [('--self-test', 'editor-tests-final'), ('--revision-tests', 'revision-tests')]:
                report = reports / f'{name}.json'
                report.unlink(missing_ok=True)
                env = dict(os.environ, ORKHON_SKIP_SETUP='1', ORKHON_TEST_DATA=str(directory / name),
                           LUMEN_TEST_RESULTS=str(report), ORKHON_TEST_HTTP_ASSET=f'http://127.0.0.1:{server.server_port}/script.js')
                process = subprocess.Popen([str(binary), flag], env=env)
                try:
                    code = process.wait(timeout=300)
                except subprocess.TimeoutExpired:
                    raise RuntimeError(f'Integration app {process.pid} did not quit; left running for inspection.')
                result = json.loads(report.read_text())
                assert code == 0 and not result.get('failures'), result
                print(f'{name}: passed', flush=True)
        finally:
            server.shutdown()
