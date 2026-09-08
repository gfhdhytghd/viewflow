#!/usr/bin/env python3
"""Read Magic Trackpad descriptors/capabilities; never grab or read input events."""
import fcntl
import hashlib
import json
from pathlib import Path
import struct

AXES = {0x2f: 'slot', 0x30: 'touch_major', 0x31: 'touch_minor',
        0x34: 'orientation', 0x35: 'x', 0x36: 'y',
        0x39: 'tracking_id', 0x3a: 'pressure'}


def inventory():
    devices = []
    for event in sorted(Path('/sys/class/input').glob('event*')):
        name = (event / 'device/name').read_text().strip()
        if 'Magic Trackpad' not in name:
            continue
        record = dict(name=name, event='/dev/input/' + event.name, axes={})
        node = event.resolve()
        for parent in node.parents:
            descriptor = parent / 'report_descriptor'
            if descriptor.exists():
                raw = descriptor.read_bytes()
                record['descriptor_hex'] = raw.hex()
                record['descriptor_sha256'] = hashlib.sha256(raw).hexdigest()
                record['descriptor_length'] = len(raw)
                record['hid_id'] = parent.name.split('.')[0]
                break
        # Query only capability ranges; discard current finger positions.
        try:
            with open(record['event'], 'rb', buffering=0) as dev:
                for axis, label in AXES.items():
                    buf = bytearray(24)
                    try:
                        fcntl.ioctl(dev, 0x80184540 + axis, buf, True)
                        _, low, high, fuzz, flat, resolution = struct.unpack('6i', buf)
                        record['axes'][label] = dict(min=low, max=high,
                            fuzz=fuzz, flat=flat, resolution=resolution)
                    except OSError:
                        pass
        except OSError as error:
            record['axis_query_error'] = str(error)
        devices.append(record)
    return dict(input_events_read=False, input_injected=False, devices=devices)

if __name__ == '__main__':
    print(json.dumps(inventory(), indent=2))
