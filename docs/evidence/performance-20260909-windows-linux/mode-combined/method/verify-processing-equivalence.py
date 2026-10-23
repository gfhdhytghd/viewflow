"""Limit inherited quality claims to byte-identical pixel/codec processing paths."""
from pathlib import Path
import json,hashlib
p=Path(__file__).resolve().parent.parent;b=p.parent
read=lambda p:json.loads(p.read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
baseline=b/'root-depth/source';candidate=p/'source'
m=read(p/'method/source-sha256.json');assert m==read(p/'method/remote-source-sha256.json') and all(sha(candidate/k)==v for k,v in m.items())
changed=[k for k in m if sha(baseline/k)!=m[k]]
assert set(changed)=={'platform/windows-reverse/main.cpp','platform/windows-reverse/performance_mode.hpp','platform/windows-reverse/performance_mode_test.cpp','platform/windows-reverse/vpl_encoder.cpp','platform/windows-window-capture/wgc_window_capture.cpp','platform/windows-window-capture/wgc_window_capture.hpp'}
main='platform/windows-reverse/main.cpp'
assert (candidate/main).read_text().replace(',std::chrono::microseconds(0));',');')==(baseline/main).read_text()
vpl='platform/windows-reverse/vpl_encoder.cpp'
def omit_request(s):
 start=s.index('HRESULT VplEncoder::request_output()');end=s.index('\nHRESULT VplEncoder::',start+1)
 return s[:start]+s[end:]
assert omit_request((candidate/vpl).read_text())==omit_request((baseline/vpl).read_text())
wgc='platform/windows-window-capture/wgc_window_capture.cpp'
def delivery(s):return s[s.index('void onFrame('):s.index('void closeState(')]
assert delivery((candidate/wgc).read_text())==delivery((baseline/wgc).read_text())
quality=read(b/'depth-quality/method/results.json');assert quality['results']['1']['frames']==quality['results']['2']['frames']==90
report=dict(source_files=len(m),unchanged_files=len(m)-len(changed),changed=changed,
 same_encoder_start_can_submit_submit_drain_poll=True,same_atlas_color_alpha_metadata_processing=True,same_wgc_frame_delivery=True,
 baseline_source_manifest_sha256=sha(b/'root-depth/method/source-sha256.json'),candidate_source_manifest_sha256=sha(p/'method/source-sha256.json'),
 inherited_quality_results_sha256=sha(b/'depth-quality/method/results.json'),quality=quality['results'],
 limitations=['The candidate changes capture cadence and when a drain starts. Frame admission and lifecycle correctness need fresh tests and are not proved by source equivalence.',
              'The inherited 90-marker full-6K synthetic RGB comparison does not certify natural images or fine text. No new encoder bitrate, chroma, quantization or resolution setting is introduced.'])
(p/'method/processing-equivalence.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
