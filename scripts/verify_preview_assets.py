#!/usr/bin/env python3
"""Verify vendored Markdown assets without Node or a network connection."""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parent.parent
assets=root/'Resources/MarkdownPreview'
manifest=json.loads((root/'Vendor/MarkdownPreview/SHA256.json').read_text())
actual={p.relative_to(assets).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in assets.rglob('*') if p.is_file()}
if actual != manifest:
    raise SystemExit('Markdown assets do not match the reviewed manifest. Regenerate them with scripts/markdown-preview/build.mjs.')
print(f'Verified {len(actual)} offline Markdown assets')
