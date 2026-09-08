from pathlib import Path
import json,hashlib,re,shutil,urllib.parse,gzip
out=Path('docs/evidence/performance-20260908/composition-path-probe');method=out/'method'
for n in ['write-composition-probe-readme.py','finalize-composition-probe-evidence.py']:
 shutil.copy2('/tmp/viewflow-'+n,method/n)
root=out.parent
for name in ['report-source.md','report.html']:
 p=root/name;s=p.read_text()
 if name.endswith('.md'):
  old='[未采用的窗口提交采集调度](capture-commit-cadence/README.md)';new=old+'、[Windows 合成路径与背景效果对照](composition-path-probe/README.md)'
 else:
  old='<a href="capture-commit-cadence/README.md">未采用的窗口提交采集调度</a>';new=old+'、<a href="composition-path-probe/README.md">Windows 合成路径与背景效果对照</a>'
 assert s.count(old)==1
 if 'composition-path-probe/README.md' not in s:s=s.replace(old,new);p.write_text(s)
 manifest=json.loads((root/'sha256.json').read_text());manifest[name]=hashlib.sha256(p.read_bytes()).hexdigest();(root/'sha256.json').write_text(json.dumps(manifest,indent=2)+'\n')
# Cross-check the frozen source version against every formal run that used it.
for directory,ledger,labels in [
 ('independent-source-and-method','viewflow-composition-probe-build-success.json',['probe-winrt-a1','probe-hostflag-b1','probe-sparse-c1','probe-elided-d1','probe-elided-d2','probe-sparse-c2','probe-hostflag-b2','probe-winrt-a2']),
 ('toggle-source','../method/composition-probe-build-success.json',['probe-toggle-ab','probe-toggle-ba'])]:
 d=json.loads((out/directory/ledger).read_text())
 for n,h in d['source_hashes'].items():assert hashlib.sha256((out/directory/n).read_bytes()).hexdigest()==h,n
 for label in labels:
  state=json.loads((out/'runs'/(label+'-state.json')).read_text(encoding='utf-8-sig'));assert state['probe_hash']==d['Hash'] and state['probe_exit']==state['observer_exit']==state['owned_tasks']==state['owned_processes']==0
for p in (out/'runs').glob('*.gz'):
 original=Path('/tmp/viewflow-composition-latency-probe')/p.name.removesuffix('.gz');assert gzip.decompress(p.read_bytes())==original.read_bytes(),p
manifest={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.rglob('*')) if p.is_file() and p!=out/'sha256.json'}
(out/'sha256.json').write_text(json.dumps(manifest,indent=2)+'\n')
for n,h in manifest.items():assert hashlib.sha256((out/n).read_bytes()).hexdigest()==h
for target in re.findall(r'\]\(([^)]+)\)',(out/'README.md').read_text()):
 if urllib.parse.urlparse(target).scheme:continue
 assert (out/target).exists(),target
m=json.loads((root/'sha256.json').read_text())
for n in ['report-source.md','report.html']:assert hashlib.sha256((root/n).read_bytes()).hexdigest()==m[n]
print('verified',len(manifest),'artifact hashes, frozen source/run identities, raw compressed bytes, README links and two root report hashes')
