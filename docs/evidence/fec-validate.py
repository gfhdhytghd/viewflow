#!/usr/bin/env python3
"""Validate final owned-netns FEC evidence; excludes the development pilot."""
import hashlib
import json
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = Path(__file__).resolve().parent
FILES = ['off-matrix', 'auto-matrix', 'off-wifi1-repeat', 'auto-wifi1-repeat',
         'off-wifi5-repeat', 'auto-wifi5-repeat']


def main():
    reference = None
    results = []
    for name in FILES:
        path = EVIDENCE / f'fec-{name}.txt'
        text = path.read_text()
        hashes = dict((path, digest) for digest, path in re.findall(
            r'^([a-f0-9]{64})  (.+)$', text, re.M))
        assert hashes and 'test executable' in hashes, path
        assert 'profile release gso off' in text, path
        if reference is None:
            reference = hashes
        assert hashes == reference, f'build/source mismatch: {path}'
        for source, digest in hashes.items():
            if source != 'test executable':
                assert hashlib.sha256((ROOT / source).read_bytes()).hexdigest() == digest, source
        rows = [json.loads(line[13:]) for line in text.splitlines()
                if line.startswith('NETEM_RESULT ')]
        assert len(rows) == (9 if 'matrix' in name else 1), path
        udp = re.findall(r'^Udp: (.+)$', text, re.M)
        assert len(udp) == 2 * len(rows), path
        udp_stats = [dict(zip(udp[i].split(), map(int, udp[i + 1].split())))
                     for i in range(0, len(udp), 2)]
        for row, socket in zip(rows, udp_stats):
            assert socket['RcvbufErrors'] == 0 and socket['SndbufErrors'] == 0, (path, row['scenario'], socket)
            assert row['survived'] and row['seconds'] >= 30, row
            assert row['send_error'] is None and row['receive_error'] is None, row
            assert row['sent'] == row['complete'] + row['frames_lost'], row
            assert row['fec'] == ('off' if name.startswith('off') else 'auto'), row
            if row['scenario'] == 'clean' or row['mode'] == 'high_quality' or row['fec'] == 'off':
                assert row['fec_parity_bytes'] == 0 and row['fec_recovered_chunks'] == 0, row
            if row['scenario'] == 'burst':
                assert row['complete_by_10s_phase'][2] > 0, row
            compact = {key: row[key] for key in [
                'scenario', 'mode', 'fec', 'seconds', 'survived', 'sent', 'complete',
                'frames_lost', 'keyframe_requests', 'nacks', 'repair_datagrams_enqueued',
                'nack_completed', 'fec_recovered_frames', 'fec_recovered_chunks',
                'fec_parity_bytes', 'udp_tx_mbps', 'latency_ms']}
            compact.update(udp_socket_errors=socket['RcvbufErrors'] + socket['SndbufErrors'], evidence=path.name, fps=row['complete'] / row['seconds'],
                           stalls=len(row['stall_ms']), max_stall_ms=max(row['stall_ms'], default=0))
            results.append(compact)
    assert len(results) == 22
    comparisons = []
    for scenario, mode in [('clean', 'auto'), ('wifi1', 'auto'), ('wifi5', 'auto'),
                           ('cap20', 'auto'), ('cap8', 'auto'), ('burst', 'auto'),
                           ('cap20', 'high_quality'), ('cap20', 'save_bandwidth'),
                           ('wifi1', 'high_quality')]:
        row = dict(scenario=scenario, mode=mode)
        for fec in ['off', 'auto']:
            selected = [r for r in results if (r['scenario'], r['mode'], r['fec']) == (scenario, mode, fec)]
            expected = 2 if scenario in ['wifi1', 'wifi5'] and mode == 'auto' else 1
            assert len(selected) == expected
            row[fec] = dict(runs=len(selected),
                            fps=[round(r['fps'], 2) for r in selected],
                            p95_ms=[r['latency_ms'][1] if r['complete'] else None for r in selected],
                            nacks=[r['nacks'] for r in selected],
                            keyframes=[r['keyframe_requests'] for r in selected],
                            stalls=[r['stalls'] for r in selected],
                            max_stall_ms=[r['max_stall_ms'] for r in selected],
                            parity_bytes=[r['fec_parity_bytes'] for r in selected],
                            recovered_chunks=[r['fec_recovered_chunks'] for r in selected])
        before, after = row['off']['p95_ms'], row['auto']['p95_ms']
        row['median_p95_ratio'] = (statistics.median(after) / statistics.median(before)
                                   if all(v is not None and v > 0 for v in before + after) else None)
        comparisons.append(row)
    output = dict(scope='owned RGBA/NVENC/real QUIC/reassembly/admission; no decode/display/input',
                  measurements=len(results), source_sha256=reference, comparisons=comparisons, rows=results)
    (EVIDENCE / 'fec-comparison.json').write_text(json.dumps(output, indent=2) + '\n')
    print('PASS (measurement integrity only; performance acceptance is separate): 22 runs; duration, survival, conservation, FEC-off/clean/HQ zero parity, burst recovery, identical build and current source hashes')
    for row in comparisons:
        print(f"{row['scenario']}/{row['mode']}: p95 off={row['off']['p95_ms']} auto={row['auto']['p95_ms']}; "
              f"NACK off={row['off']['nacks']} auto={row['auto']['nacks']}; "
              f"stalls off={row['off']['stalls']} auto={row['auto']['stalls']}")


if __name__ == '__main__':
    main()
