#!/usr/bin/env python3
"""Resolve libc PCs against a verified matching ELF symbol table, preserving gaps.

Input is perf script -F +symoff,+dsoff. Verify perf buildid-list against readelf
before use. Does not infer missing callers or replace unknown private modules.
"""
import argparse,bisect,re,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('input',type=Path);p.add_argument('libc',type=Path);p.add_argument('--build-id',required=True);p.add_argument('--mmap',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
notes=subprocess.check_output(['readelf','-n',str(a.libc)],text=True)
assert ('Build ID: '+a.build_id) in notes, 'libc build ID mismatch'
symbols=[]
for l in subprocess.check_output(['objdump','-t',str(a.libc)],text=True).splitlines():
 m=re.match(r'([0-9a-f]+)\s+\w*\s+F\s+\.text\s+([0-9a-f]+)\s+(\S+)',l)
 if m: symbols.append((int(m[1],16),int(m[2],16),m[3]))
symbols.sort();starts=[v[0] for v in symbols];resolved=0;out=[]
base=None
if a.mmap:
 for l in a.mmap.read_text().splitlines():
  if 'PERF_RECORD_MMAP2' in l and a.build_id in l and str(a.libc) in l:
   m=re.search(r'\[(0x[0-9a-f]+)\([^)]*\) @ (0x[0-9a-f]+|0) ',l)
   if m: base=int(m[1],16)-int(m[2],16);break
 assert base is not None, 'missing verified libc mapping'
for l in a.input.read_text().splitlines():
 if base is not None and '[unknown]' in l and ('('+str(a.libc)+')') in l:
  ip=re.match(r'\s*([0-9a-f]+) ',l)
  if ip: l=l.replace('('+str(a.libc)+')','('+str(a.libc)+f'+0x{int(ip[1],16)-base:x})')
 m=re.search(r'\[unknown\] \(([^)]+libc\.so\.6)\+0x([0-9a-f]+)\)',l)
 if m:
  offset=int(m[2],16);i=bisect.bisect_right(starts,offset)-1
  if i>=0 and offset<symbols[i][0]+symbols[i][1]:
   l=l.replace('[unknown]',symbols[i][2]+f'+0x{offset-symbols[i][0]:x}',1);resolved+=1
 l=re.sub(r'(\([^)]*)\+0x[0-9a-f]+\)',r'\1)',l)
 out.append(l)
a.output.write_text('\n'.join(out)+'\n');print('resolved_libc_frames',resolved,'symbols',len(symbols))
