#!/usr/bin/env python3
"""Theme metadata for legacy Lexilla lexers, derived from upstream symbols."""
from pathlib import Path
import re,json
root=Path(__file__).resolve().parents[1]
header=(root/'Vendor/lexilla/include/SciLexer.h').read_text()
numbers={name:int(value) for name,value in re.findall(r'#define\s+(SCE_\w+)\s+(\d+)',header)}
rows=[];coverage={}
for source in sorted((root/'Vendor/lexilla/lexers').glob('Lex*.cxx')):
 text=source.read_text();names=re.findall(r'LexerModule\s+\w+\([^;]*?"([\w]+)"',text,re.S)
 styles={}
 for token in sorted(set(re.findall(r'\bSCE_\w+',text))):
  if token in numbers and numbers[token]<256:styles.setdefault(numbers[token],[]).append(token)
 for name in names:
  coverage[name]=len(styles)
  for number,symbols in sorted(styles.items()):rows.append((name,number,' '.join(symbols)))
output='// Generated from vendored Lexilla; do not edit by hand.\nstatic const struct { const char *lexer; int style; const char *name; } upstreamStyles[] = {\n'
output+=''.join('    {"%s", %d, "%s"},\n'%row for row in rows)+'};\n'
(root/'Sources/EditorBridge/LexerStyleNames.inc').write_text(output)
(root/'work/style-coverage.json').write_text(json.dumps(coverage,indent=2))
print(f'Generated {len(rows)} upstream style mappings for {len(coverage)} lexers')
