from pathlib import Path
import json,re,math,statistics
b=Path(__file__).resolve().parent.parent;inputs=json.loads((b/'method/inputs.json').read_text());runs={};wanted=set(map(int,(b/'method/markers.txt').read_text().split()))
for name in inputs['inputs']:
 text=(b/(name+'.log')).read_text();values=[]
 for line in text.splitlines():
  if line.startswith('quality_frame '):
   r=dict(re.findall(r'(\w+)=([^ ]+)',line));values.append({k:int(v) if k=='marker' else float(v) for k,v in r.items()})
 assert len(values)==len(wanted)==90 and {r['marker'] for r in values}==wanted
 assert 'quality_complete frames=90 full_pixels_per_frame=21233664' in text and 'gl_error=0 opaque_alpha=verified' in text
 runs[name]={'aggregate_psnr_db':-10*math.log10(statistics.mean(r['mse'] for r in values)),'maximum_channel_error':max(r['max_error'] for r in values),'frames':values}
ref={r['marker']:r for r in runs['mft-speed0']['frames']}
for name,s in runs.items():
 delta=[r['psnr']-ref[r['marker']]['psnr'] for r in s['frames']];s['paired_psnr_delta_db']={'median':statistics.median(delta),'min':min(delta),'max':max(delta)}
summary={'scope':'same 90 common marker IDs, every RGB pixel against exact synthetic shader, first encoded occurrence, GPU decoding/conversion/reduction; not natural image/text fidelity proof','pixels_per_frame':21233664,'runs':runs}
(b/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print({n:{k:v for k,v in s.items() if k!='frames'} for n,s in runs.items()})
