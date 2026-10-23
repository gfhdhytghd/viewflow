"""Archive the passive root/nested compositor comparison and invalid top-marker attempt."""
from pathlib import Path
import hashlib,json,shutil
b=Path(__file__).resolve().parent.parent
read=lambda p:json.loads(p.read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
labels=['topology-inner-c1','topology-direct-d1','topology-direct-d2','topology-inner-c2'];all_names=['topology-nested-a1','topology-root-b1',*labels];records=[]
for name in all_names:
 p=b/'transport/runs'/name;s=read(p/'state.json');assert s['native_hash_before']==s['native_hash_after']=='875E56F9E746B5DAEA37814DC67C54495A9B313CD6F0EB6B2652A59F057F42FE'
 assert not s['after']['processes'] and not s['after']['port'] and not s['remaining_proxies'] and s['before']['installed']==s['after']['installed']
 source=Path(s['nested_state']['root']);n=read(source/'state.json');target=b/'transport/topology'/name;target.mkdir(exist_ok=True,parents=True)
 if s['presentation_topology']=='root-headless':assert n['rule_disabled'] and not n['remaining_clients'] and n['before_plugins']==n['after_plugins'] and n['configerrors_before']==n['configerrors_after']
 else:assert n['nested_stopped'] and n['transport_trial']=='passed' and not n['remaining_clients']
 for file in ['state.json','hyprland.lua','compositor.log','inner.py','launch.py','rule.lua']:
  if (source/file).exists():shutil.copy2(source/file,target/file)
 if name=='topology-root-b1':assert not read(p/'analysis-rejection.json')['run_qualified'] and not (p/'summary.json').exists();continue
 summary=read(p/'summary.json');assert summary['run_qualified'];records.append({'trial':name,'presentation_topology':s['presentation_topology'],'summary':summary,'native_source_sha256':s['native_hash_before'],'linux_binaries':s['linux_binaries']})
 for path,h in s['linux_binaries'].items():assert sha(Path(path))==h
 if name in labels:assert s['marker_physical_y']==256 and (p/'desktop-first.ppm').exists()
write(b/'transport/topology-comparison.json',records)
p=b/'root-headless';m=read(p/'method/source-sha256.json');assert len(m)==14 and all(sha(p/'source'/k)==v for k,v in m.items());assert '100% tests passed' in (p/'method/ctest.log').read_text()
write(p/'method/observer-source-sha256.json',{str(f.relative_to(p/'source')):sha(f) for f in sorted((p/'source/observer').rglob('*')) if f.is_file()})
table=['| Trial | Compositor | Distinct FPS | Median upper ms | P95 upper ms | Maximum upper ms |','|---|---|---:|---:|---:|---:|']
for row in records:
 if row['trial'] not in labels:continue
 r=row['summary'];t=r['latency_high_ms'];table.append(f"| {row['trial']} | {row['presentation_topology']} | {r['desktop_distinct_hz']:.3f} | {t['median']:.3f} | {t['p95']:.3f} | {t['max']:.3f} |")
(p/'README.md').write_text('# Root compositor versus nested compositor\n\nThe same installed canonical VPL source (875E56F9) and the same passive Linux presenter are used in this A/B/B/A comparison. Both render the complete 6144×3456 stream at scale 2. The passive presenter only changes its app class, lets the wrapper own the temporary window rule, and skips the user\'s global touchpad subscription. Its decoder/upload/draw code is otherwise the canonical implementation. Two Linux CTests pass.\n\n'+ '\n'.join(table)+'\n\nThe root arm creates one far-away 6144×3456@60 virtual output on the existing DRM compositor. It uses a unique class rule with no initial focus and no focus. The rule is disabled on cleanup and its Lua handle cleared; this inert named runtime rule is reused by the following root arm. The private output is removed, monitor rectangles and plugin lists match, and original input/main services are not reconfigured. No input events are injected. The nested arms keep the previous isolated compositor method. Neither arm measures physical screen scanout.\n\nThe first top-marker root attempt recorded 1201 screenshots but zero valid marker frames, and was explicitly rejected. The layer inventory includes existing root desktop layers in the top region; the exact pixels that invalidated the first marker were not retained, so the cause is not established. The repeated comparison moves the fixture fiducial to physical y=256 and observes that interior region in **both** arms; stream dimensions stay 6K. First-ROI images and the observed layer inventory are retained. The direct-d1 image was visually checked as unobstructed complementary black/white marker rows. The earlier nested top-marker result remains a separate record, outside the four-row comparison.\n\nThe P95 ranges overlap: root 81.70–85.47 ms, nested 80.97–95.08 ms. This does not support attributing the latency gap to an extra nested desktop frame. The installed source remains unchanged, and the 60 ms target is still unmet. There are now 81 qualified full-route trials, plus two explicitly rejected profiling/top-marker attempts.\n')
for p,title,body in [(b/'README.md','## 实际合成器与嵌套桌面对照','相同已安装源程序和相同 Linux 接收器的四轮交叉对照中，实际合成器独立虚拟屏 P95 为 81.70–85.47ms，嵌套桌面为 80.97–95.08ms，区间重叠，未发现嵌套层造成固定额外一帧的证据。首轮顶部标记失败已作废；复测将标记移到窗口内部，两侧使用相同标记和观察位置，并保留图片及桌面叠层记录。[测量方法与结果](root-headless/README.md)。'),(b/'transport/README.md','## Root and nested compositor comparison','One initial nested control and four repeated topology trials bring the qualified count to 81. The initial root top-marker attempt is explicitly rejected, then both arms use an interior marker ROI with saved images. Root and nested P95 ranges overlap. [Detailed topology and cleanup record](../root-headless/README.md).')]:
 t=p.read_text();assert title not in t;p.write_text(t+'\n'+title+'\n\n'+body+'\n')
print('Root/nested topology archive complete; source-fixture remote audit and final manifest refresh remain')
