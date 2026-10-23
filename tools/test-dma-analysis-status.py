#!/usr/bin/env python3
"""CPU-only checks that stopped experiments cannot become accepted baselines."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

path = Path(__file__).with_name('analyze-dma-6k60.py')
spec = importlib.util.spec_from_file_location('dma_analysis', path)
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)

for name, evidence in [
    ('aborted.json', {'status': 'aborted'}),
    ('guest-aborted.json', {'status': 'aborted'}),
    ('cleanup-unconfirmed.json', {'status': 'unconfirmed'}),
    ('drain-blocked.json', {}),
    ('normal-stop-blocked.json', {}),
    ('task-result.json', {'exit': 1}),
    ('task-result.json', {'exit': 0, 'status': 'aborted'}),
]:
    with tempfile.TemporaryDirectory() as directory:
        run = Path(directory)
        (run / name).write_text(json.dumps(evidence))
        result = analysis.analyze(run)
        assert result['performance_valid'] is False
        assert result['stable_baseline'] is False
        assert 'source_published_atlas_pts_in_loop' not in result

with tempfile.TemporaryDirectory() as directory:
    subprocess.run([sys.executable, str(path), '--run', directory], check=True,
                   capture_output=True)
    result = json.loads((Path(directory) / 'analysis-v2.json').read_text())
    assert result['status'] == 'unavailable'
    assert result['performance_valid'] is False

print('PASS: aborted, failed, unconfirmed and missing evidence are not valid baselines')

# Two proxies must remain separate; a startup-straddling interval cannot be
# clipped into an apparently valid steady motion rate.
def feedback(proxy, begin, end, clock=1):
    return (f'ivshmem-presentation-counts id={proxy} output=DP-4 '
            f'interval_begin_ns={begin} interval_end_ns={end} clock_id={clock} '
            'requested=1202 presented=1200 discarded=0 invalid=0 '
            'untracked_commits=0 pending=2 unique_pts=1190 duplicate_pts=10')
result = analysis.presentation_intervals('\n'.join([
    feedback(1, 0, 20_000_000_000),
    feedback(1, 20_000_000_000, 40_000_000_000),
    feedback(2, 20_000_000_000, 40_000_000_000),
    feedback(3, 20_000_000_000, 40_000_000_000, clock=0),
    feedback(4, 20, 20),
]), 10_000_000_000, 50_000_000_000)
assert result['complete_intervals_inside_motion'] == 2
assert len(result['intervals']) == 3
assert result['intervals'][0]['fully_inside_motion'] is False
assert all(row['feedback_arrival_fps'] == 60 for row in result['intervals'])
assert result['intervals'][1]['unique_source_feedback_fps'] == 59.5
print('PASS: feedback intervals preserve proxy identity, clock and motion bounds')
