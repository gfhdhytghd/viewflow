"""Per-window capture and submitted-frame cadence; never combines window streams."""
import collections,json,re,statistics,sys
from pathlib import Path
rows=collections.defaultdict(lambda:collections.defaultdict(list))
for line in Path(sys.argv[1]).read_text().splitlines():
    kind=line.split(' ',1)[0]
    if kind not in ('profile_capture','profile_shared_capture'):continue
    d={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
    if (d.get('width'),d.get('height'))!=(6144,3456):continue
    rows[d['id']][kind].append(d)
def stats(v):
    v=sorted(v)
    return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,len(v)*95//100)],'max':v[-1]} if v else {'n':0}
result={}
for ident,kinds in rows.items():
    out={}
    for kind,records in kinds.items():
        stamps=sorted(set(d['capture'] for d in records))
        gaps=[(b-a)/10000 for a,b in zip(stamps,stamps[1:])]
        out[kind]={'records':len(records),'unique_captures':len(stamps),'capture_span_fps':(len(stamps)-1)*1e7/(stamps[-1]-stamps[0]) if len(stamps)>1 else None,'capture_gap_ms':stats(gaps),'gaps_over_25ms':sum(x>25 for x in gaps)}
    source={d['capture'] for d in kinds['profile_capture']}
    selected={d['capture'] for d in kinds['profile_shared_capture']}
    if selected:
        lo,hi=min(selected),max(selected)
        interior={x for x in source if lo<=x<=hi}
        out['selection_coverage']={'captured_within_selected_span':len(interior),'selected_captured':len(interior & selected),'unselected':len(interior-selected),'selected_missing_capture_record':len(selected-source)}
    result[str(ident)]=out
print(json.dumps({'scope':'6K per-window WGC timestamps; coverage excludes before/after selected span; capture cadence is not physical display FPS','windows':result},indent=2))
