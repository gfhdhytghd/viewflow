"""Compare fixed native-commit windows around the existing observer capture.

These are adjacent samples in one stream, not a randomized observer A/B test.
No desktop timing or displayed-frame rate can be inferred after observation ends.
"""
from pathlib import Path
import gzip
import json
import re
import statistics

B = Path(__file__).resolve().parent
out = []
for p in sorted((B.parent / 'production-pair/runs').iterdir()):
    desktop = gzip.decompress((p / 'desktop-marker.log.gz').read_bytes()).decode()
    receiver = gzip.decompress((p / 'isolated-receiver-stderr.log.gz').read_bytes()).decode()
    observed = [int(x) for x in re.findall(r'desktop-marker frame=\d+ input=\d+ present_qpc=(\d+)', desktop)]
    frequency = int(re.search(r'observer pid=\d+ qpc_frequency=(\d+)', desktop)[1])
    events = [(int(f), int(t) / int(hz)) for f, t, hz in re.findall(
        r'atlas-native-mutation frame=(\d+) qpc=(\d+) frequency=(\d+)', receiver)]
    last = observed[-1] / frequency
    phases = {}
    for name, start, end in [('during_last10', last - 11, last - 1), ('after10', last + 2, last + 12)]:
        values = [(f, t) for f, t in events if start <= t < end]
        assert values and events[-1][1] >= end
        gaps = [(y[1] - x[1]) * 1000 for x, y in zip(values, values[1:])]
        phases[name] = dict(events=len(values), seconds=end-start, hz=len(values)/(end-start),
            median_gap_ms=statistics.median(gaps), max_gap_ms=max(gaps),
            over_25ms=sum(g > 25 for g in gaps), frame_span=[values[0][0], values[-1][0]])
    out.append(dict(label=p.name, phases=phases))
(B / 'observer-adjacent-windows.json').write_text(json.dumps(out, indent=2) + '\n')
print('Recomputed four pairs of fixed ten-second native-commit windows')
