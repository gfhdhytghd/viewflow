#!/usr/bin/env python3
"""Launch a paired IVSHMEM window receiver in the current Hyprland session."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--peer', required=True, type=Path)
    args = parser.parse_args()
    while True:
        try:
            instances = json.loads(subprocess.check_output(
                ['hyprctl', 'instances', '-j'], timeout=5))
            # Prefer the most recently started accessible desktop. Never reuse
            # a signature inherited from a previous compositor process.
            for instance in reversed(instances):
                env = dict(os.environ, HYPRLAND_INSTANCE_SIGNATURE=instance['instance'],
                           WAYLAND_DISPLAY=instance['wl_socket'])
                monitors = json.loads(subprocess.check_output(
                    ['hyprctl', 'monitors', '-j'], env=env, timeout=5))
                if any(not m.get('disabled') for m in monitors):
                    os.execve(args.peer, [str(args.peer), '--config', str(args.config)], env)
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            print(f'IVSHMEM receiver waiting for desktop: {error}', flush=True)
        time.sleep(2)


if __name__ == '__main__':
    main()
