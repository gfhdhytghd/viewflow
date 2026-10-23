#!/usr/bin/env python3
"""Use generated codec bytes with zero tiles; no windows or input are created."""
import json
from pathlib import Path
import struct
import subprocess
import sys

root = Path(sys.argv[1])
wire = (root / 'macos-h264-window.vfrv').read_bytes()
records = []
offset = 0
while offset < len(wire):
    size, = struct.unpack_from('<I', wire, offset)
    frame = wire[offset + 4:offset + 4 + size]
    assert len(frame) == size
    offset += 4 + size
    count, = struct.unpack_from('<I', frame, 28)
    position = 32
    for _ in range(count):
        position += 40
        length, = struct.unpack_from('<I', frame, position)
        position += 4 + length
        flags, = struct.unpack_from('<I', frame, position)
        position += 12 + (8 if flags & 4 else 0)
    empty = frame[:28] + struct.pack('<I', 0) + frame[position:]
    records.append(struct.pack('<I', len(empty)) + empty)
assert len(records) == 4
for mode in ('latency', 'frame-rate'):
    run = subprocess.run([str(root / 'viewflow-macos-windows-multi'), 'present',
                          '--performance-mode', mode], input=b''.join(records),
                         capture_output=True, timeout=10)
    assert run.returncode == 0, run.stderr.decode(errors='replace')
    assert run.stdout == b'', 'empty scene generated return input'
    print(json.dumps({'mode': mode, 'generated_frames': len(records), 'exit_code': run.returncode,
                      'return_input_bytes': len(run.stdout), 'stderr': run.stderr.decode(errors='replace')}))
