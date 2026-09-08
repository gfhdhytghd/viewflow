#!/usr/bin/env python3
"""Physical Magic Trackpad -> Viewflow native MT bridge (wire ABI 2).

Run on Linux. Local input stays available; no exclusive grab is implemented.
inspect reads capabilities only. forward is a user-operated physical test.
"""
import argparse
import fcntl
import json
import os
import select
import shlex
import signal
import struct
import subprocess
import sys
import time
from linux_forward import Device, EVENT, EV_SYN, EV_ABS, SYN_REPORT, SYN_DROPPED

EV_KEY, BTN_LEFT = 1, 0x110
MAJOR, MINOR, ORIENTATION, PRESSURE = 0x30, 0x31, 0x34, 0x3a
HEADER = b'VFTP\x02\0\0\0'
WIDTH, HEIGHT = 16000, 11490


def report(contacts, button, ticks):
    if len(contacts) > 5:
        raise ValueError('maximum five contact records')
    data = bytearray(72)
    struct.pack_into('<BBH IHH', data, 0, len(contacts), int(button), 0,
                     ticks & 0xffffffff, WIDTH, HEIGHT)
    for i, c in enumerate(contacts):
        struct.pack_into('<BBHH6B', data, 12 + 12*i, *c)
    return bytes(data)


class NativeEncoder:
    def __init__(self, x_range, y_range):
        self.ranges = x_range, y_range
        self.previous = {}
        self.button = False
        self.next_id = 0
        self.peak = 0

    def frames(self, snapshot, button, ticks):
        keys = [k for k in self.previous if k in snapshot]
        keys += [k for k in sorted(snapshot) if k not in keys][:5-len(keys)]
        retired = set(self.previous) - set(keys)
        frames = []
        if retired:
            frames.append(report([(v[0], int(k not in retired), *v[2:])
                                  for k, v in self.previous.items()], button, ticks))
        used = {v[0] for v in self.previous.values()}
        current = {}
        for k in keys:
            if k in self.previous:
                cid = self.previous[k][0]
            else:
                while self.next_id in used:
                    self.next_id = (self.next_id + 1) % 15
                cid = self.next_id
                self.next_id = (cid + 1) % 15
                used.add(cid)
            x, y, pressure, major, minor, orientation = snapshot[k]
            xy = []
            for value, (low, high) in zip((x, y), self.ranges):
                if high <= low:
                    raise ValueError('invalid physical axis range')
                value = min(high, max(low, value))
                xy.append(((value-low)*32767 + (high-low)//2)//(high-low))
            # hid-magicmouse exposes contact diameters in raw-byte units * 4
            # and negates the device orientation. The driver does not expose
            # raw Size; use mean contact diameter and record this approximation.
            major, minor = [min(255, max(0, v//4)) for v in (major, minor)]
            size = (major + minor)//2
            angle = min(7, max(0, 4-orientation))
            current[k] = (cid, 1, *xy, min(255, max(0, pressure)), major, minor,
                          size, angle, 2)  # ordinary finger; anatomical identity unavailable
        if current != self.previous or bool(button) != self.button:
            frames.append(report(list(current.values()), button, ticks))
        self.previous, self.button = current, bool(button)
        self.peak = max(self.peak, len(current))
        return frames


class NativeDevice(Device):
    def __init__(self, path):
        super().__init__(path)
        fcntl.ioctl(self.fd, 0x400445a0, struct.pack('i', time.CLOCK_MONOTONIC))
        self.button = False
        self.extra = []
        for code in (PRESSURE, MAJOR, MINOR, ORIENTATION):
            try:
                self.absinfo(code)
                self.extra.append(code)
            except OSError:
                pass

    def resync(self):
        super().resync()
        for code in self.extra:
            buf = bytearray(4*(self.capacity+1))
            struct.pack_into('i', buf, 0, code)
            fcntl.ioctl(self.fd, 0x8000450a | (len(buf) << 16), buf, True)
            for slot, value in zip(self.slots, struct.unpack_from(f'{self.capacity}i', buf, 4)):
                slot[code] = value
        keys = bytearray(96)
        fcntl.ioctl(self.fd, 0x80604518, keys, True)  # EVIOCGKEY; resync pressed button
        self.button = bool(keys[BTN_LEFT//8] & (1 << (BTN_LEFT%8)))

    def snapshot(self):
        xy = super().snapshot()
        return {k: (*v, self.slots[k[0]].get(PRESSURE, 5),
                     self.slots[k[0]].get(MAJOR, 80), self.slots[k[0]].get(MINOR, 80),
                     self.slots[k[0]].get(ORIENTATION, 0)) for k, v in xy.items()}

    def event(self, kind, code, value):
        if not self.dropped:
            if kind == EV_KEY and code == BTN_LEFT:
                self.button = bool(value)
            elif kind == EV_ABS and code in self.extra and 0 <= self.slot < self.capacity:
                self.slots[self.slot][code] = value
        return super().event(kind, code, value)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode', choices=['inspect', 'forward'])
    p.add_argument('--device', required=True)
    p.add_argument('--ssh')
    p.add_argument('--receiver', default='/Applications/VFTrackpadHost.app/Contents/MacOS/VFTrackpadHost')
    args = p.parse_args()
    if args.mode == 'forward' and (not args.ssh or args.ssh.startswith('-')):
        p.error('forward requires an SSH destination')
    dev = NativeDevice(args.device)
    child = None
    sent = 0
    encoder = NativeEncoder(dev.x_range, dev.y_range)
    try:
        if args.mode == 'inspect':
            print(json.dumps(dict(name=dev.name, slots=dev.capacity, x=dev.x_range,
                                  y=dev.y_range, extra_axes=dev.extra, events_read=False,
                                  exclusive_grab=False, wire_abi=2)))
            return 0
        base = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ServerAliveInterval=5',
                '-o', 'ServerAliveCountMax=3', args.ssh]
        result = subprocess.run(base + [shlex.quote(args.receiver) + ' --driver-status'],
                                check=True, capture_output=True, text=True)
        status = json.loads(result.stdout)
        if status.get('abi') != 2 or status.get('native_profile') != 1:
            raise ValueError('install native bridge version 4 before forwarding')
        if not status.get('native_multitouch_attached'):
            raise ValueError('AppleMultitouchDevice has not attached; native handshake still needs diagnosis')
        print(result.stdout.strip(), file=sys.stderr)
        dev.resync()
        child = subprocess.Popen(base + [shlex.quote(args.receiver) + ' --receive-stdin'],
                                 stdin=subprocess.PIPE, bufsize=0)
        def send(data):
            nonlocal sent
            view = memoryview(data)
            while view:
                n = child.stdin.write(view)
                if not n:
                    raise BrokenPipeError('SSH receiver closed')
                view = view[n:]
            if len(data) == 72:
                sent += 1
        send(HEADER)
        for frame in encoder.frames(dev.snapshot(), dev.button, time.monotonic_ns()//100000):
            send(frame)
        print('Forwarding real touches; Linux input remains active. Ctrl-C stops.', file=sys.stderr)
        pending = bytearray()
        while child.poll() is None:
            if not select.select([dev.fd], [], [], 0.25)[0]:
                continue
            try:
                data = os.read(dev.fd, EVENT.size*64)
            except BlockingIOError:
                continue
            if not data:
                break
            pending.extend(data)
            while len(pending) >= EVENT.size:
                sec, usec, kind, code, value = EVENT.unpack(pending[:EVENT.size])
                del pending[:EVENT.size]
                snapshot = dev.event(kind, code, value)
                if snapshot is not None:
                    for frame in encoder.frames(snapshot, dev.button, (sec*1000000+usec)//100):
                        send(frame)
    except KeyboardInterrupt:
        pass
    finally:
        os.close(dev.fd)
        if child:
            try:
                child.stdin.close()
            except BrokenPipeError:
                pass
            child.wait()
            print(json.dumps(dict(sender_reports=sent, sender_peak_contacts=encoder.peak,
                                  exclusive_grab=False)), file=sys.stderr)
    return child.returncode if child else 0


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        print(f'Native forwarding failed: {e}', file=sys.stderr)
        sys.exit(1)
