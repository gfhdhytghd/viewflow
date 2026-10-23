"""Classify sampled latency by actual source capture identity; retain all samples."""
import json,re,sys,statistics
from pathlib import Path
r=Path(__file__).resolve().parent;tag=sys.argv[1]
first={};captures={}
for line in (r/f'{tag}-guest.log').read_text().splitlines():
 if not line.startswith('profile_shared_capture '):continue
 d={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
 key=(d['id'],d['capture'],d['version'])
 first.setdefault(key,d['pts']);captures[d['pts']]=(key,first[key])
def stats(values):
 values=sorted(values)
 return {'n':len(values),'p50':statistics.median(values),'p95':values[min(len(values)-1,int(.95*len(values)))],'max':values[-1]} if values else {'n':0}
d=json.loads((r/f'{tag}-stages.json').read_text());groups={k:[] for k in ['first_capture_publication','repeated_capture_publication','unattributed']};replays=[]
for row in d['rows']:
 pts=row['frame_identity']['pts'];capture=captures.get(pts)
 kind='unattributed' if capture is None else 'first_capture_publication' if capture[1]==pts else 'repeated_capture_publication'
 groups[kind].append(row['total_ms'])
 if kind=='repeated_capture_publication':replays.append({'pts':pts,'first_pts':capture[1],'source_identity':capture[0],'total_ms':row['total_ms']})
print(json.dumps({'scope':'all sampled rows retained; identity classification only, no latency threshold exclusion; first publication does not prove first pixel content or continuous presentation; software feedback excludes photons','all_samples':stats([x['total_ms'] for x in d['rows']]),'groups':{k:stats(v) for k,v in groups.items()},'replays':replays},indent=2))
