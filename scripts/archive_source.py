#!/usr/bin/env python3
from pathlib import Path
import zipfile
root=Path(__file__).resolve().parent.parent
with zipfile.ZipFile(root/'outputs/Orkhon Code Source.zip','w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
 for item in ['.gitignore','.github','Makefile','CONTRIBUTING.md','SECURITY.md','Package.swift','README.md','LICENSE','Sources','Tests','Resources','Vendor','scripts']:
  path=root/item
  for f in ([path] if path.is_file() else sorted(path.rglob('*'))):
   if not f.is_file() or any(p in {'.git','.build','__pycache__'} for p in f.parts):continue
   if f.suffix in {'.o','.a','.dylib','.pyc'}:continue
   archive.write(f,Path('Orkhon Code Source')/f.relative_to(root))
print('Source archive created')
