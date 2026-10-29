#!/usr/bin/env python3
"""Inspect the A / A+B sensitivity study; no performance results are filtered.

Pass --a-only before commit B exists. Full verification uses the frozen source
hashes and the named A revision, rather than trusting the evidence git caption.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'docs/evidence'
LOSS = ['wifi1o', 'wifi5o', 'burst', 'reorder', 'wifi1', 'wifi5']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--a-only', action='store_true')
    parser.add_argument('--a-revision', help='Verify A source hashes against this commit')
    args = parser.parse_args()
    rows = []
    binaries = {}
    source_hashes = {}
    variants = ['a'] if args.a_only else ['a', 'ab']
    for variant in variants:
        for path in sorted(EVIDENCE.glob(f'stalls2-{variant}-*-s*.txt')):
            text = path.read_text()
            hashes = {name: digest for digest, name in re.findall(r'^([0-9a-f]{64})  (.+)$', text, re.M)}
            binary = hashes.pop('test executable')
            if variant not in binaries:
                binaries[variant], source_hashes[variant] = binary, hashes
            assert binaries[variant] == binary and source_hashes[variant] == hashes, path.name
            for name, digest in hashes.items():
                if variant == 'a' and args.a_revision:
                    data = subprocess.check_output(['git', 'show', f'{args.a_revision}:{name}'], cwd=ROOT)
                else:
                    data = (ROOT / name).read_bytes()
                assert hashlib.sha256(data).hexdigest() == digest, (path.name, name)
            dependency = re.search(r'^quinn-proto v0\.11\.19(.*)$', text, re.M)
            assert dependency is not None, path.name
            assert ('vendor/quinn-proto' in dependency[1]) == (variant == 'ab'), path.name
            rr = [json.loads(l[13:]) for l in text.splitlines() if l.startswith('NETEM_RESULT ')]
            assert len(rr) == 1, path.name
            r = rr[0]
            assert r['survived'] and r['seconds'] >= 30, path.name
            assert r['send_error'] is None and r['receive_error'] is None, path.name
            assert r['sent'] == r['complete'] + r['frames_lost'], path.name
            probes = [json.loads(l.removeprefix('NETEM_ORDER_PROBE ')) for l in text.splitlines() if l.startswith('NETEM_ORDER_PROBE ')]
            if r['scenario'] in ['wifi1o', 'wifi5o', 'reorder', 'wifi1', 'wifi5']:
                assert len(probes) == 1 and probes[0]['scenario'] == r['scenario'], path.name
                assert [p['profile'] for p in probes[0]['rows']] == ['paced', 'burst']
                if r['scenario'] in ['wifi1o', 'wifi5o']:
                    assert all(p['reordered'] == p['max_sequence_displacement'] == 0 for p in probes[0]['rows']), path.name
                    assert 'rate 1Gbit' in text, path.name
                if r['scenario'] == 'reorder':
                    assert any(p['reordered'] > 0 for p in probes[0]['rows']), path.name
                    assert 'reorder 1%' in text, path.name
            udp = re.findall(r'^Udp: (InDatagrams .+)\nUdp: (.+)$', text, re.M)
            assert len(udp) == 1
            counters = dict(zip(udp[0][0].split(), map(int, udp[0][1].split())))
            assert counters['InErrors'] == counters['RcvbufErrors'] == 0, (path.name, counters)
            assert len(r['stall_ms']) == len(r['stall_ranges_s']), path.name
            for ms, (start, end) in zip(r['stall_ms'], r['stall_ranges_s']):
                assert abs(ms - (end-start)*1000) < .1, path.name
            r['udp_snmp'] = counters
            r['order_probe'] = probes[0]['rows'] if probes else []
            r['variant'], r['evidence'] = variant, path.name
            r['fps'] = r['complete'] / r['seconds']
            r['p95_ms'] = r['latency_ms'][1] if r['complete'] else None
            r['longest_stall_ms'] = max(r['stall_ms'], default=0)
            r['post_loss_longest_stall_ms'] = max((max(0, end-max(20, start))*1000 for start, end in r['stall_ranges_s']), default=0)
            r.pop('target_trace_s_kbps_fps')
            rows.append(r)
        expected = [(s, f, str(seed)) for s in LOSS for f in ['off', 'auto'] for seed in [1, 2]]
        if variant == 'a':
            expected += [(s, f, '1') for s in ['clean', 'cap20', 'cap8'] for f in ['off', 'auto']]
        actual = [(r['scenario'], r['fec'], r['seed']) for r in rows if r['variant'] == variant]
        assert sorted(expected) == sorted(actual), (variant, len(actual))
    out = {'a_revision': args.a_revision, 'source_sha256': source_hashes, 'executable_sha256': binaries, 'rows': rows}
    (EVIDENCE / ('stalls2-a-summary.json' if args.a_only else 'stalls2-comparison.json')).write_text(json.dumps(out, indent=2) + '\n')
    print(f'PASS: {len(rows)} unfiltered cases; coherent source/binary per variant; registry/patched dependency, FIFO sequence probes, count conservation, zero receive errors.')
    print('Zero complete-frame runs:', sum(r['complete'] == 0 for r in rows))


if __name__ == '__main__':
    main()
