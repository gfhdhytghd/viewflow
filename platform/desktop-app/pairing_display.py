"""Read existing Windows parking-display geometry without changing displays."""
import re
import subprocess


def windows_share_bounds(program):
    result = subprocess.run([str(program)], capture_output=True, text=True, timeout=5,
                            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    if result.returncode: return None
    candidates = []
    for line in result.stdout.splitlines():
        fields = [part.strip() for part in line.split('|')]
        if len(fields) != 4 or 'virtual' not in fields[1].lower(): continue
        flags = re.fullmatch(r'flags=(\d+)', fields[2])
        bounds = re.fullmatch(r'(-?\d+),(-?\d+) (\d+)x(\d+)', fields[3])
        if not flags or not int(flags[1]) & 1 or not bounds: continue
        x, y, width, height = map(int, bounds.groups())
        if width > 0 and height > 0: candidates.append([x, y, x + width, y + height])
    # Ambiguous desktops need a UI choice, not a guessed capture target.
    return candidates[0] if len(candidates) == 1 else None
