"""Eligibility for CPU/GPU overlap at first Map, not measured overlap duration."""
import re,json,sys
from pathlib import Path
lines=Path(sys.argv[1]).read_text().splitlines();valid=set();samples=[]
for line in lines:
 if line.startswith('profile_shared_capture '):
  d={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
  if d.get('captured_bands')==1 and (d['width'],d['height'])==(6144,3456):valid.add(d['pts'])
for line in lines:
 if line.startswith('profile_band_overlap '):
  d={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
  if d['pts'] in valid:samples.append(d['first_copy_before_last_ready'])
print(json.dumps({'scope':'6K banded frames; last-band completion query before first Map, not GPU duration or proof CPU overlapped GPU','banded_submissions':len(valid),'observations':len(samples),'last_band_not_ready':sum(samples),'all_bands_already_ready':len(samples)-sum(samples),'eligible_fraction':sum(samples)/len(samples) if samples else None},indent=2))
