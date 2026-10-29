#!/usr/bin/env python3
"""Observe only owned UDP packets in the launcher's private netns.

Probe sequence displacement is not a decrypted QUIC packet-number metric.
The caller resets shaping after this probe, before its timed media workload.
"""
import argparse
import json
import os
import socket
import struct
import threading
import time


def probe(profile):
    receiving = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiving.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    receiving.bind(('127.0.0.1', 0))
    receiving.settimeout(.1)
    sending = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    observed = []
    stopped = threading.Event()

    def collect():
        while not stopped.is_set():
            try:
                data = receiving.recv(2048)
                sequence, sent = struct.unpack('!Qd', data[:16])
                observed.append((sequence, (time.monotonic() - sent) * 1000))
            except socket.timeout:
                pass

    worker = threading.Thread(target=collect)
    worker.start()
    count = 2048 if profile == 'burst' else 512
    try:
        for sequence in range(count):
            payload = struct.pack('!Qd', sequence, time.monotonic()) + bytes(1184)
            sending.sendto(payload, receiving.getsockname())
            if profile == 'paced':
                time.sleep(.0002)
            elif sequence % 512 == 511:
                time.sleep(.03)
        time.sleep(.4)
    finally:
        stopped.set()
        worker.join()
        receiving.close()
        sending.close()
    highest = -1
    reordered = over129 = maximum = 0
    seen = set()
    for sequence, _ in observed:
        distance = max(0, highest - sequence)
        reordered += distance > 0
        over129 += distance >= 129
        maximum = max(maximum, distance)
        highest = max(highest, sequence)
        seen.add(sequence)
    delays = sorted(delay for _, delay in observed)
    assert delays, 'probe delivered no packets'
    return {'profile': profile, 'sent': count, 'received': len(observed),
            'unique': len(seen), 'missing': count - len(seen),
            'reordered': reordered, 'distance_ge_129': over129,
            'max_sequence_displacement': maximum,
            'delay_p50_p95_ms': [delays[int((len(delays)-1)*p)] for p in [.5, .95]]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario', required=True)
    args = parser.parse_args()
    assert os.environ.get('VF_NETEM_PRIVATE') == '1', 'private netns required'
    rows = [probe(profile) for profile in ['paced', 'burst']]
    print('NETEM_ORDER_PROBE ' + json.dumps({'scenario': args.scenario, 'rows': rows}), flush=True)
    if args.scenario == 'reorder':
        assert any(row['reordered'] > 0 for row in rows), 'explicit reorder produced no observed reordering'
    if args.scenario in ['wifi1o', 'wifi5o']:
        assert all(row['reordered'] == 0 for row in rows), 'FIFO order violated'


if __name__ == '__main__':
    main()
