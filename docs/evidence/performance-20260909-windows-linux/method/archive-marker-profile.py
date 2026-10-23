"""Seal marker-to-PTS diagnostic pairing without changing the full-route criterion."""
from pathlib import Path
import json, hashlib, subprocess, shutil
b=Path(__file__).resolve().parent.parent;p=b/'marker-profile'
read=lambda p:json.loads(p.read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=read(p/'method/source-sha256.json');assert len(m)==14 and all(sha(p/'source'/k)==v for k,v in m.items())
assert '100% tests passed out of 2' in (p/'method/build.log').read_text()
labels=['marker-profile-a1','markerinterval-default-a1','markerinterval-zero-b1','markerinterval-zero-b2','markerinterval-default-a2']
table=['| Trial | WGC minimum us | FPS | Full P95 upper ms | Draw to WGC copy median / P95 ms | Submit to color median / P95 ms |','|---|---:|---:|---:|---:|---:|']
records=[]
for label in labels:
    d=b/'transport/runs'/label;s=read(d/'state.json');r=read(d/'summary.json');a=read(d/'marker-stage-summary.json')
    assert r['run_qualified'] and a['paired']==r['steady_distinct'] and not a['excluded'] and a['duplicate_marker_ids']==0
    assert s['native_hash_before']==s['native_hash_after'] and s['before']['installed']==s['after']['installed']=='C914CC47A55494EDD96B7C8BB35BD99EE769740D127156241B45246D98F293DB'
    assert not s['after']['processes'] and not s['after']['port'] and not s['remaining_proxies']
    assert all(s['mode_restored'][k]==s['mode_before'][k] for k in ['schema','mode','max_pending','scope'])
    nested=Path(s['nested_state']['root']);n=read(nested/'state.json');assert n['nested_stopped'] and n['transport_trial']=='passed' and not n['remaining_clients']
    target=b/'transport/nested'/label;target.mkdir(parents=True,exist_ok=True)
    for name in ['state.json','hyprland.lua','compositor.log','inner.py','launch.py']:
        if (nested/name).exists():shutil.copy2(nested/name,target/name)
    subprocess.run(['python3',str(b/'method/check-encoder-accounting.py'),str(d),'--bounded-stop'],check=True)
    cap=a['stages']['fixture_pre_draw_to_wgc_copy_queued_ms'];enc=a['stages']['source_submit_to_color_ready_ms']
    table.append(f"| {label} | {s.get('wgc_interval_us','default')} | {r['desktop_distinct_hz']:.3f} | {r['latency_high_ms']['p95']:.3f} | {cap['median']:.3f} / {cap['p95']:.3f} | {enc['median']:.3f} / {enc['p95']:.3f} |")
    records.append(dict(trial=label,state_native=s['native_hash_before'],linux_binaries=s['linux_binaries'],full_route=r,stages=a))
assert len({x['state_native'] for x in records[1:]})==1
assert len({x['linux_binaries']['/tmp/viewflow-reverse-marker-profile/viewflow_linux_reverse'] for x in records})==1
(p/'method/results.json').write_text(json.dumps(records,indent=2)+'\n')
(p/'README.md').write_text('# Exact fixture marker and native PTS stage pairing\n\nThe isolated Linux receiver reads two 3 KiB luma rows from the decoded 6K CUDA image, recognizes the complementary 24-bit fixture marker and logs its actual PTS. The source fixture, observer, full-resolution path and original full-route analyzer are unchanged. This adds synchronous GPU readback overhead, reported separately rather than subtracted. Fourteen source inputs are archived; the release build and two Linux CTests pass.\n\n'+'\n'.join(table)+'\n\nAll steady desktop observations match exactly one decoded marker and native PTS; there are no ambiguous marker IDs in these five trials. Capture copy logs are joined by WGC timestamp, while pixel age is established by the decoded fixture identity and fixture QPC. WGC timestamps alone are not treated as pixel birth times. Every raw pair and statistic is retained under transport/runs.\n\nThe four interval trials use the same Windows executable, with default/zero/zero/default intervals. Draw-to-WGC-copy median remains 24.39–24.54 ms. Zero interval does not remove this dominant delay. Encoder completion is about 21 ms at the median, Linux decode about 4.5 ms, and transport about 1–2 ms using the sampled clock envelope. Desktop scheduling remains variable; the best individual P95 is 61.29 ms, still above 60. Quantiles are not additive, and these diagnostics do not measure physical scanout.\n\nAll source/receiver tasks exit normally, native identities and restored mode values match, and private proxies/compositors/outputs are removed. No production behavior is changed. The full-route archive now contains 106 qualified trials.\n')
for f,heading,body in [(b/'README.md','## 同一画面的完整阶段配对','新增五轮带标记的完整链路诊断，累计 106 轮有效测试。绘制到 WGC 复制约 24.4–24.6 ms，编码约 21 ms；零采集间隔未消除固定采集等待，最好单轮 P95 为 61.29 ms，仍未达标。[逐帧证据](marker-profile/README.md)。'),(b/'transport/README.md','## Marker-to-PTS stage diagnosis','Five qualified diagnostic trials bring the total to 106. Each steady observed marker maps uniquely to the decoded PTS, allowing actual source/encode/network/decode/desktop stage pairing. Instrumentation overhead and clock-envelope limits remain explicit. [Details](../marker-profile/README.md).')]:
    t=f.read_text();assert heading not in t;f.write_text(t+'\n'+heading+'\n\n'+body+'\n')
print('Five marker-profile trials archived')
