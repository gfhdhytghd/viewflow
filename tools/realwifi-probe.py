#!/usr/bin/env python3
"""Owned two-host UDP probe. No capture, input, interface or qdisc changes.

Depth = highest previously received send sequence minus late sequence.
Relative transit removes minimum observed transit; clocks need not synchronize.
Clock drift remains included. Loss includes socket and application drops.
"""
import argparse
import json
import socket
import struct
import time


def percentiles(values):
    values = sorted(values)
    return [values[int((len(values)-1)*p)] for p in (.5, .95, .99)] if values else []


def summarize(records, count):
    highest = -1
    seen = set()
    depths, transit = [], []
    duplicates = 0
    for seq, sent, received in records:
        if seq in seen:
            duplicates += 1
            continue
        seen.add(seq)
        depths.append(max(0, highest-seq))
        highest = max(highest, seq)
        transit.append((received-sent)*1000)
    runs, run = [], 0
    for seq in range(count):
        if seq not in seen:
            run += 1
        elif run:
            runs.append(run)
            run = 0
    if run:
        runs.append(run)
    baseline = min(transit) if transit else 0
    late = [d for d in depths if d]
    return dict(sent=count, unique=len(seen), duplicates=duplicates,
                loss_pct=100*(count-len(seen))/count,
                reordered=len(late), reordered_pct=100*len(late)/max(1,len(seen)),
                depth_all_p50_p95_p99=percentiles(depths),
                depth_late_p50_p95_p99=percentiles(late), max_depth=max(depths, default=0),
                depth_ge129=sum(d >= 129 for d in depths),
                relative_transit_p50_p95_p99_ms=percentiles([t-baseline for t in transit]),
                relative_transit_max_ms=max(transit, default=baseline)-baseline,
                loss_run_p50_p95_p99=percentiles(runs), max_loss_run=max(runs, default=0))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('role', choices=['send', 'receive'])
    p.add_argument('--bind', required=True)
    p.add_argument('--peer', required=True)
    p.add_argument('--port', type=int, default=45871)
    p.add_argument('--rate', type=float, default=20)
    p.add_argument('--seconds', type=float, default=10)
    p.add_argument('--burst', action='store_true')
    a = p.parse_args()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if a.role == 'receive':
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4*1024*1024)
        s.bind((a.bind, a.port))
        s.settimeout(30)
        rows = []
        while True:
            data, peer = s.recvfrom(2048)
            now = time.monotonic()
            if peer[0] != a.peer:
                continue
            if data.startswith(b'END!'):
                count = int(data[4:])
                # Sender repeats END; first END starts a bounded late-packet drain.
                s.settimeout(.5)
                try:
                    while True:
                        data, peer = s.recvfrom(2048)
                        now = time.monotonic()
                        if peer[0] == a.peer and len(data) == 1200:
                            seq, sent = struct.unpack('!Qd', data[:16])
                            rows.append((seq, sent, now))
                except socket.timeout:
                    break
            if len(data) == 1200:
                seq, sent = struct.unpack('!Qd', data[:16])
                rows.append((seq, sent, now))
        print(json.dumps(dict(summarize(rows, count), recv_buffer=s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF))), flush=True)
    else:
        s.bind((a.bind, 0))
        target = (a.peer, a.port)
        origin = time.monotonic()
        count = 0
        while time.monotonic()-origin < a.seconds:
            due = origin + (count//125/60 if a.burst else count*9600/(a.rate*1e6))
            delay = due-time.monotonic()
            if delay > 0:
                time.sleep(delay)
            s.sendto(struct.pack('!Qd', count, time.monotonic())+bytes(1184), target)
            count += 1
        elapsed = time.monotonic()-origin
        for _ in range(3):
            s.sendto(b'END!'+str(count).encode(), target)
            time.sleep(.05)
        print(json.dumps(dict(sent=count, seconds=elapsed, actual_mbps=count*9600/elapsed/1e6)), flush=True)
    s.close()


if __name__ == '__main__':
    main()
