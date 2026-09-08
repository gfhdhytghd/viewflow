from pathlib import Path
import json,hashlib,re,shutil,urllib.parse
out=Path('docs/evidence/performance-20260908/capture-commit-cadence');method=out/'method'
for name in ['commit-nested-driver.py','commit-nested-ab.py']:
 p=Path('/tmp/viewflow-'+name);old=p.read_text();shutil.copyfile(p,method/name.replace('.py','-tested.py'))
 new=old.replace("  try:ctl('dispatch','hl.dsp.exit()',env=inner)\n  except Exception as e:state['exit_error']=str(e)","  if inner is not None:\n   try:ctl('dispatch','hl.dsp.exit()',env=inner)\n   except Exception as e:state['exit_error']=str(e)\n  else:\n   os.kill(pid,signal.SIGTERM)")
 assert new!=old;p.write_text(new);shutil.copyfile(p,method/name)
p=Path('/tmp/viewflow-save-commit-cadence-evidence.py');s=p.read_text();s=s.replace("out=Path('docs/evidence", "# Refuse to overwrite the tested snapshot after source restoration.\nfor n,h in json.loads(Path('/tmp/viewflow-commit-cadence-trial-source-sha256.json').read_text()).items():\n assert hashlib.sha256(Path(n).read_bytes()).hexdigest()==h,n\nout=Path('docs/evidence",1);p.write_text(s);shutil.copyfile(p,method/'save-commit-cadence-evidence.py')
for name in ['commit-cadence-final-state.py','commit-cadence-final-state.json','commit-cadence-production-restored.json','restore-commit-prototype.py','write-commit-cadence-readme.py','finalize-commit-evidence.py']:
 shutil.copyfile('/tmp/viewflow-'+name,method/name)
p=out/'README.md';s=p.read_text();s=s.replace('所有实例均终止，自有外层输出移除，前后 root monitor、focus、plugin 列表逐项相等。','所有实例均终止，自有外层输出移除，前后 root monitor、focus、plugin 列表逐项相等。归档时另给驱动增加未注册嵌套环境时的清理 guard：只终止已知自有 PID，避免将退出命令发给默认实例；本轮没有进入该未就绪清理路径。原始受测 driver/AB 脚本另存为 `*-tested.py`，改后的脚本只做 Python 语法检查，不将它冒充已重跑的性能版本。');p.write_text(s)
root=out.parent
for name in ['report-source.md','report.html']:
 p=root/name;s=p.read_text()
 if name.endswith('.md'):
  old='[捕获帧到达唤醒优化](capture-readiness/README.md)';new=old+'、[未采用的窗口提交采集调度](capture-commit-cadence/README.md)'
 else:
  old='<a href="capture-readiness/README.md">捕获帧到达唤醒优化</a>';new=old+'、<a href="capture-commit-cadence/README.md">未采用的窗口提交采集调度</a>'
 assert s.count(old)==1 and 'capture-commit-cadence/README.md' not in s;s=s.replace(old,new);p.write_text(s)
 manifest=json.loads((root/'sha256.json').read_text());manifest[name]=hashlib.sha256(p.read_bytes()).hexdigest();(root/'sha256.json').write_text(json.dumps(manifest,indent=2)+'\n')
manifest={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.rglob('*')) if p.is_file() and p!=out/'sha256.json'}
(out/'sha256.json').write_text(json.dumps(manifest,indent=2)+'\n')
for n,h in manifest.items():assert hashlib.sha256((out/n).read_bytes()).hexdigest()==h
for target in re.findall(r'\]\(([^)]+)\)',(out/'README.md').read_text()):
 if urllib.parse.urlparse(target).scheme:continue
 assert (out/target).exists(),target
m=json.loads((root/'sha256.json').read_text())
for n in ['report-source.md','report.html']:assert hashlib.sha256((root/n).read_bytes()).hexdigest()==m[n]
print('verified',len(manifest),'artifact hashes, README relative links and two root report hashes')
