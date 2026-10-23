from pathlib import Path
import shutil,json
r=Path('/home/wilf/data/viewflow');b=r/'docs/evidence/performance-20260909-windows-linux';p=b/'root-performance';p.mkdir();(p/'method').mkdir();(p/'source').mkdir()
files=set(json.loads((b/'root-lifecycle/method/source-sha256.json').read_text()))
for name in ['compact_alpha_plane.hpp','compact_alpha_plane.cpp','frame_changes.hpp','frame_changes_test.cpp','alpha_async_probe.cpp','diagnostics.hpp','performance_mode.hpp','performance_mode_test.cpp']:files.add('platform/windows-reverse/'+name)
for f in sorted(files):
 d=p/'source'/f;d.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/f,d)
for name in ['stage-build.py','build.cmd']:
 s=(b/'root-lifecycle/method'/name).read_text().replace('reverse-root-lifecycle-20260909','reverse-root-performance-20260909')
 if name=='build.cmd':s=s.replace('viewflow_wgc_capture_contract_test --parallel','viewflow_wgc_capture_contract_test viewflow_reverse_frame_changes_test viewflow_reverse_performance_mode_test viewflow_reverse_alpha_async_probe --parallel')
 (p/'method'/name).write_text(s)
shutil.copy2(__file__,p/'method/prepare.py')
