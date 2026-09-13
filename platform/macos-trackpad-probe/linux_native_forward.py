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
import threading
from linux_forward import Device, EVENT, EV_SYN, EV_ABS, SYN_REPORT, SYN_DROPPED

EV_KEY, BTN_LEFT = 1, 0x110
MAJOR, MINOR, ORIENTATION, PRESSURE = 0x30, 0x31, 0x34, 0x3a
HEADER = b'VFTP\x02\0\0\0'
WIDTH, HEIGHT = 16000, 11490


def captured_for_route(status, config, peer_pid, alive, destination):
    """Use compositor capture ownership, never keyboard focus or cursor XY."""
    return (alive and peer_pid > 0 and config.get('remote', '').rsplit(':', 1)[0] == destination
            and status.get('connected') == 1 and status.get('phase') == 3
            and isinstance(status.get('remote'), list) and len(status['remote']) == 5
            and status['remote'][0] == config.get('pointer', {}).get('cursor_monitor_id'))


class ViewflowRoute:
    def __init__(self, config_path, destination):
        self.config_path = config_path
        self.destination = destination.rsplit('@', 1)[-1]
        self.last_active = False
        self.identity = None
        self.query_failed = False

    def active(self):
        try:
            with open(self.config_path) as f:
                config = json.load(f)
            ready = os.path.join(os.environ['XDG_RUNTIME_DIR'], 'viewflow/cursor-ready')
            with open(ready) as f:
                pid = int(f.read())
            alive = os.path.basename(os.readlink(f'/proc/{pid}/exe')) == 'vf-cursor-peer'
            with open(f'/proc/{pid}/cmdline', 'rb') as f:
                command = f.read().decode().rstrip('\0').split('\0')
            at = command.index('--config')
            alive = alive and os.path.realpath(command[at+1]) == os.path.realpath(self.config_path)
            identity = (pid, config.get('remote'), config.get('pointer', {}).get('cursor_monitor_id'))
            if identity != self.identity:
                self.last_active = False
                self.identity = identity
            if not alive or config.get('remote', '').rsplit(':', 1)[0] != self.destination:
                self.last_active = False
                return False
        except (OSError, ValueError, KeyError, IndexError):
            self.last_active = False
            self.identity = None
            return False
        try:
            result = subprocess.run(['hyprctl', 'repl', 'return hl.plugin.viewflow.capture_status()'],
                                    capture_output=True, text=True, timeout=0.2, check=True)
            status = json.loads(result.stdout)
            if not isinstance(status, dict) or not {'connected', 'phase', 'remote'} <= status.keys():
                raise ValueError('incomplete capture status')
            self.last_active = captured_for_route(status, config, pid, alive, self.destination)
            if self.query_failed:
                print('HID capture query recovered', file=sys.stderr)
            self.query_failed = False
            return self.last_active
        except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
            # Observation failure is not a return-to-Linux event. Keep the
            # last confirmed owner only while the same live peer/target remains.
            if not self.query_failed:
                print('HID capture query unavailable; retaining confirmed route', file=sys.stderr)
            self.query_failed = True
            return self.last_active


class AsyncRoute:
    """Keep compositor IPC off the physical-report reader's hot path."""
    def __init__(self, route, interval=0.004):
        self.route = route
        self.value = route.active()
        self.stopped = threading.Event()
        self.interval = interval
        self.worker = threading.Thread(target=self._poll, name='hid-route', daemon=True)
        self.worker.start()

    def _poll(self):
        while not self.stopped.wait(self.interval):
            self.value = self.route.active()

    def active(self):
        return self.value

    def close(self):
        self.stopped.set()
        self.worker.join(timeout=0.5)


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

    def frames(self, snapshot, button, ticks, preserve_cadence=False):
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
            x, y, pressure, major, minor, orientation = snapshot[k][:6]
            native_fields = snapshot[k][6:]
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
            size = native_fields[0] if native_fields else (major + minor)//2
            angle = min(7, max(0, 4-orientation))
            # The native MT bridge represents a physical click with pressure
            # 120 as well as the button bit (VoodooInput constructReportGated).
            # Linux pressure is a different device scale; passing it unchanged
            # can describe a light contact while the physical switch is down.
            native_pressure = min(255, max(0, pressure)) if native_fields else (120 if button else min(255, max(0, pressure)))
            current[k] = (cid, 1, *xy, native_pressure, major, minor,
                          size, angle, native_fields[1] if native_fields else 2)
        if current != self.previous or bool(button) != self.button or (preserve_cadence and (current or button)):
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


class NativeRawDevice:
    """Read-only Magic Trackpad BT reports; no feature writes or device grab."""
    def __init__(self, path, event_path):
        from pathlib import Path
        raw = Path('/sys/class/hidraw') / Path(path).name / 'device'
        event = Path('/sys/class/input') / Path(event_path).name / 'device'
        if raw.resolve() not in event.resolve().parents:
            raise ValueError('hidraw and evdev must identify the same physical device')
        identity = (raw / 'uevent').read_text()
        if not any(value in identity for value in ('HID_ID=0005:0000004C:00000324', 'HID_ID=0005:0000004C:00000265')):
            raise ValueError('raw input requires a supported Bluetooth Magic Trackpad')
        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        self.name, self.capacity, self.extra = 'Magic Trackpad native BT', 16, []
        # The existing Mac bridge encodes this coordinate domain. Unlike the
        # evdev calibration ranges, this preserves the native signed XY units.
        self.x_range, self.y_range = (-4067,4067), (-2603,2603)
        self.button = False
        self.contacts = {}

    def resync(self):
        pass # Each raw packet is a complete device snapshot.

    def snapshot(self):
        return self.contacts

    def feed(self, data):
        if not data or data[0] != 0x31:
            return None
        if len(data) < 4 or (len(data)-4)%9 or (len(data)-4)//9 > 15:
            raise ValueError('malformed native touchpad report')
        contacts = {}
        for offset in range(4,len(data),9):
            c = data[offset:offset+9]
            bits = int.from_bytes(c[:4], 'little')
            state, finger = bits >> 29, (bits >> 26)&7
            # hid-magicmouse considers (byte3 & 0xc0) == 0x80 down:
            # both states 4 and 5 retain contact. Preserve native start (3)
            # as well; 6/7 are departure/stop, not continuing contact.
            if state not in (3,4,5):
                continue
            if finger == 7:
                # Physical reports can carry the reserved three-bit value.
                # ABI 2 accepts 0..6; use its Undefined classification (0)
                # without dropping the contact, button edge, or connection.
                # Do not guess an anatomical finger or reuse another contact.
                finger = 0
                self.unknown_classifications = getattr(self, 'unknown_classifications', 0) + 1
                if self.unknown_classifications == 1:
                    print('HID reserved finger classification 7 mapped to Undefined (0); continuing',
                          file=sys.stderr)
            x, y = bits&8191, (bits>>13)&8191
            if x&4096: x-=8192
            if y&4096: y-=8192
            cid = c[8]&15
            if cid in contacts:
                raise ValueError('duplicate native contact identifier')
            contacts[cid] = (x,-y,c[7],c[4]*4,c[5]*4,4-(c[8]>>5),c[6],finger)
        self.contacts, self.button = contacts, bool(data[1]&1)
        return contacts


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode', choices=['inspect', 'forward'])
    p.add_argument('--device', required=True)
    p.add_argument('--hidraw', default=os.environ.get('VIEWFLOW_HIDRAW'),
                   help='Matching Bluetooth hidraw node, or auto (also VIEWFLOW_HIDRAW)')
    p.add_argument('--ssh')
    p.add_argument('--receiver', default='/Applications/Viewflow.app/Contents/MacOS/Viewflow')
    p.add_argument('--route-config', help='Follow this active Viewflow cursor route; release while local')
    args = p.parse_args()
    if args.mode == 'forward' and (not args.ssh or args.ssh.startswith('-')):
        p.error('forward requires an SSH destination')
    if args.hidraw == 'auto':
        from pathlib import Path
        event = (Path('/sys/class/input') / Path(args.device).name / 'device').resolve()
        matches = [str(Path('/dev') / node.name) for node in Path('/sys/class/hidraw').glob('hidraw*')
                   if (node / 'device').resolve() in event.parents]
        if len(matches) != 1:
            p.error('cannot identify one hidraw node for the configured touchpad')
        args.hidraw = matches[0]
    dev = NativeRawDevice(args.hidraw,args.device) if args.hidraw else NativeDevice(args.device)
    child = None
    sent = 0
    trace_buttons = os.environ.get('VIEWFLOW_HID_TRACE_BUTTONS') == '1'
    traced_button = False
    encoder = NativeEncoder(dev.x_range, dev.y_range)
    route = AsyncRoute(ViewflowRoute(args.route_config, args.ssh or '')) if args.route_config else None
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
            nonlocal sent, traced_button
            view = memoryview(data)
            while view:
                n = child.stdin.write(view)
                if not n:
                    raise BrokenPipeError('SSH receiver closed')
                view = view[n:]
            if len(data) == 72:
                sent += 1
                if trace_buttons and bool(data[1]) != traced_button:
                    traced_button = bool(data[1])
                    print(json.dumps(dict(hid_button='sent', down=traced_button,
                        scan_ticks=struct.unpack_from('<I', data, 4)[0],
                        wall_ns=time.time_ns(), report=sent, contacts=data[0],
                        active_contacts=sum(data[13+12*i] != 0 for i in range(data[0])))),
                        file=sys.stderr, flush=True)
        send(HEADER)
        forwarding = route.active() if route else True
        for frame in encoder.frames(dev.snapshot() if forwarding else {}, dev.button if forwarding else False,
                                    time.monotonic_ns()//100000):
            send(frame)
        print(f'HID route={"macos" if forwarding else "linux"}; following Viewflow={route is not None}.', file=sys.stderr)
        pending = bytearray()
        while child.poll() is None:
            if route:
                active = route.active()
                if active != forwarding:
                    forwarding = active
                    for frame in encoder.frames(dev.snapshot() if active else {}, dev.button if active else False,
                                                time.monotonic_ns()//100000):
                        send(frame)
                    print(f'HID route={"macos" if active else "linux"}', file=sys.stderr)
            if not select.select([dev.fd], [], [], 0.01 if route else 0.25)[0]:
                continue
            try:
                data = os.read(dev.fd, 4096 if args.hidraw else EVENT.size*64)
            except BlockingIOError:
                continue
            if not data:
                break
            if args.hidraw:
                snapshot = dev.feed(data)
                if snapshot is None:
                    continue
                if route:
                    active = route.active()
                    if active != forwarding:
                        forwarding = active
                        print(f'HID route={"macos" if active else "linux"}', file=sys.stderr)
                for frame in encoder.frames(snapshot if forwarding else {}, dev.button if forwarding else False,
                                            time.monotonic_ns()//100000, preserve_cadence=True):
                    send(frame)
                continue
            pending.extend(data)
            while len(pending) >= EVENT.size:
                sec, usec, kind, code, value = EVENT.unpack(pending[:EVENT.size])
                del pending[:EVENT.size]
                if trace_buttons and kind == EV_KEY and code == BTN_LEFT:
                    print(json.dumps(dict(hid_button='physical', down=bool(value),
                        scan_ticks=((sec*1000000+usec)//100)&0xffffffff,
                        wall_ns=time.time_ns(), route=forwarding)), file=sys.stderr, flush=True)
                snapshot = dev.event(kind, code, value)
                if snapshot is not None:
                    # Recheck at the physical frame boundary, after compositor
                    # processing; buffered Linux touches cannot extend an old lease.
                    if route:
                        active = route.active()
                        if active != forwarding:
                            forwarding = active
                            print(f'HID route={"macos" if active else "linux"}', file=sys.stderr)
                    for frame in encoder.frames(snapshot if forwarding else {}, dev.button if forwarding else False,
                                                (sec*1000000+usec)//100):
                        send(frame)
    except KeyboardInterrupt:
        pass
    finally:
        if route:
            route.close()
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
