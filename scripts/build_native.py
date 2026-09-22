#!/usr/bin/env python3
from pathlib import Path
import subprocess, concurrent.futures, os
root=Path(__file__).resolve().parent.parent
out=root/'work/build/native';out.mkdir(parents=True,exist_ok=True)
includes=['scintilla/include','scintilla/src','scintilla/cocoa','lexilla/include','lexilla/lexlib']
flags=['-std=c++17','-O3','-DNDEBUG','-mmacosx-version-min=13.0','-fvisibility=hidden','-Wno-deprecated-declarations']+[f'-I{root/"Vendor"/p}' for p in includes]
groups={'scintilla':list((root/'Vendor/scintilla/src').glob('*.cxx'))+list((root/'Vendor/scintilla/cocoa').glob('*.mm')),'lexilla':list((root/'Vendor/lexilla/lexlib').glob('*.cxx'))+list((root/'Vendor/lexilla/lexers').glob('*.cxx'))+[root/'Vendor/lexilla/src/Lexilla.cxx']}
def compile_one(args):
 name,src=args; obj=out/(name+'_'+src.stem+'.o')
 if not obj.exists() or obj.stat().st_mtime<src.stat().st_mtime:
  cmd=['clang++']+flags+(['-fobjc-arc'] if src.suffix=='.mm' else [])+['-c',str(src),'-o',str(obj)]
  p=subprocess.run(cmd,capture_output=True,text=True)
  if p.returncode: raise RuntimeError(p.stderr)
 return str(obj)
for name,sources in groups.items():
 print(f'Building {name}: {len(sources)} translation units',flush=True)
 with concurrent.futures.ThreadPoolExecutor(max_workers=min(8,os.cpu_count() or 4)) as pool: objects=list(pool.map(compile_one,[(name,s) for s in sources]))
 subprocess.run(['libtool','-static','-o',str(out/f'lib{name}.a')]+objects,check=True)
