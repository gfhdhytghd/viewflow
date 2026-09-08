#!/usr/bin/env python3
"""User-operated Magic Trackpad → authenticated SSH → DriverKit experiment.

No dependencies. Opening the device queries only metadata; forwarding starts
only when invoked with the `forward` subcommand. `inspect` never reads events.
"""
import argparse
import fcntl
import json
import os
import select
import shlex
import struct
import subprocess
import sys

EV_SYN, EV_ABS = 0, 3
SYN_REPORT, SYN_DROPPED = 0, 3
SLOT, X, Y, TRACKING = 0x2f, 0x35, 0x36, 0x39
EVENT = struct.Struct('@llHHi')
HEADER = b'VFTP\x01\x00\x00\x00'


def report(contacts):
    if len(contacts) > 5:
        raise ValueError('at most five HID contact records')
    output = bytearray(32)
    output[0], output[31] = 1, len(contacts)
    for i, (cid, x, y, down) in enumerate(contacts):
        struct.pack_into('<BBHH', output, 1 + 6*i, 3 if down else 2, cid, x, y)
    return bytes(output)


class Encoder:
    """Stable contact IDs with explicit liftoffs before ID/slot reuse."""
    def __init__(self, x_range, y_range):
        if x_range[1] <= x_range[0] or y_range[1] <= y_range[0]:
            raise ValueError('invalid coordinate ranges')
        self.ranges = x_range, y_range
        self.previous = {}
        self.next_id = 0

    def frames(self, snapshot):
        # Preserve selected contacts if the source has more than five fingers.
        keys = [key for key in self.previous if key in snapshot]
        keys += [key for key in sorted(snapshot) if key not in keys][:5-len(keys)]
        current = {}
        retired = set(self.previous) - set(keys)
        frames = []
        if retired:
            # A separate frame lets all old liftoffs fit, even when five new
            # fingers replace five old ones within a single Linux report.
            frames.append(report([(*value, key not in retired)
                                  for key, value in self.previous.items()]))
        used = {v[0] for v in self.previous.values()}
        for key in keys:
            if key in self.previous:
                cid = self.previous[key][0]
            else:
                while self.next_id in used:
                    self.next_id = (self.next_id + 1) % 256
                cid = self.next_id
                self.next_id = (cid + 1) % 256
                used.add(cid)
            xy = []
            for raw, (low, high) in zip(snapshot[key], self.ranges):
                raw = min(high, max(low, raw))
                xy.append(((raw-low)*32767 + (high-low)//2)//(high-low))
            current[key] = (cid, *xy)
        if current != self.previous:
            frames.append(report([(*value, True) for value in current.values()]))
        self.previous = current
        return frames


class Device:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            name = bytearray(256)
            fcntl.ioctl(self.fd, 0x81004506, name, True)  # EVIOCGNAME(256)
            self.name = bytes(name).split(b'\0', 1)[0].decode(errors='replace')
            # This experiment routes a specific Magic Trackpad, not a keyboard.
            if 'Magic Trackpad' not in self.name:
                raise ValueError('selected device is not a Magic Trackpad')
            slots = self.absinfo(SLOT)
            if slots[1] != 0 or not 0 <= slots[2] < 256:
                raise ValueError('unsupported MT slot range')
            self.capacity = slots[2] + 1
            self.slot = slots[0]
            self.x_range = tuple(self.absinfo(X)[1:3])
            self.y_range = tuple(self.absinfo(Y)[1:3])
            self.slots = [{} for _ in range(self.capacity)]
            self.dropped = False
        except BaseException:
            os.close(self.fd)
            raise

    def absinfo(self, code):
        buf = bytearray(24)
        fcntl.ioctl(self.fd, 0x80184540 + code, buf, True)
        return struct.unpack('6i', buf)

    def resync(self):
        for code in (TRACKING, X, Y):
            buf = bytearray(4*(self.capacity+1))
            struct.pack_into('i', buf, 0, code)
            fcntl.ioctl(self.fd, 0x8000450a | (len(buf) << 16), buf, True)
            for slot, value in zip(self.slots, struct.unpack_from(f'{self.capacity}i', buf, 4)):
                slot[code] = value
        self.slot = self.absinfo(SLOT)[0]

    def snapshot(self):
        return {(i, slot[TRACKING]): (slot[X], slot[Y])
                for i, slot in enumerate(self.slots)
                if slot.get(TRACKING, -1) >= 0 and X in slot and Y in slot}

    def event(self, kind, code, value):
        if kind == EV_SYN and code == SYN_DROPPED:
            self.dropped = True
        elif kind == EV_SYN and code == SYN_REPORT:
            if self.dropped:
                self.resync()
                self.dropped = False
            return self.snapshot()
        elif not self.dropped and kind == EV_ABS:
            if code == SLOT:
                self.slot = value
            elif code in (TRACKING, X, Y) and 0 <= self.slot < self.capacity:
                self.slots[self.slot][code] = value
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['inspect', 'forward'])
    parser.add_argument('--device', required=True)
    parser.add_argument('--ssh', help='existing SSH destination, e.g. linhaikuo@172.16.105.83')
    parser.add_argument('--receiver', default='/Applications/VFTrackpadHost.app/Contents/MacOS/VFTrackpadHost')
    parser.add_argument('--grab', action='store_true', help='route this touchpad exclusively during forwarding')
    args = parser.parse_args()
    if args.mode == 'forward' and (not args.ssh or args.ssh.startswith('-')):
        parser.error('forward requires an SSH destination')
    dev = Device(args.device)
    child = None
    try:
        if args.mode == 'inspect':
            print(json.dumps(dict(name=dev.name, slots=dev.capacity,
                                  x=dev.x_range, y=dev.y_range, events_read=False)))
            return 0
        # Verify the installed backend before routing any physical input.
        base = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ServerAliveInterval=5',
                '-o', 'ServerAliveCountMax=3', args.ssh]
        subprocess.run(base + [shlex.quote(args.receiver) + ' --driver-status'], check=True)
        if args.grab:
            print('Exclusive mode: Linux will NOT receive input from this touchpad until forwarding stops. Use Ctrl-C on the keyboard to stop.', file=sys.stderr, flush=True)
            fcntl.ioctl(dev.fd, 0x40044590, 1)  # EVIOCGRAB; fd close always releases
        dev.resync()
        encoder = Encoder(dev.x_range, dev.y_range)
        child = subprocess.Popen(base + [shlex.quote(args.receiver) + ' --receive-stdin'],
                                 stdin=subprocess.PIPE, bufsize=0)
        def send(data):
            view = memoryview(data)
            while view:
                n = child.stdin.write(view)
                if not n:
                    raise BrokenPipeError('SSH stopped accepting input')
                view = view[n:]
        send(HEADER)
        for frame in encoder.frames(dev.snapshot()):
            send(frame)
        print('Forwarding physical touches. Ctrl-C ends forwarding and releases contacts.', file=sys.stderr)
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
                _, _, kind, code, value = EVENT.unpack(pending[:EVENT.size])
                del pending[:EVENT.size]
                snapshot = dev.event(kind, code, value)
                if snapshot is not None:
                    for frame in encoder.frames(snapshot):
                        send(frame)
    except KeyboardInterrupt:
        pass
    finally:
        os.close(dev.fd)
        if child:
            # EOF is the release boundary at the receiver; there is no 33 ms
            # expiry. Process death is also handled by DriverKit client Stop.
            try:
                child.stdin.close()
            except BrokenPipeError:
                pass
            child.wait()
    return child.returncode if child else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'Viewflow forwarding failed: {error}', file=sys.stderr)
        sys.exit(1)
