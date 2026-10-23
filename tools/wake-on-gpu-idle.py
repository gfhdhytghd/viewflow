#!/usr/bin/env python3
"""One-shot busy -> sustained idle notice to an existing Codex thread.

Never launches a benchmark, stops a workload, or starts another agent.
Run only when an idle notification is wanted; this is not a boot service.
"""
import argparse
import fcntl
import os
from pathlib import Path
import subprocess
import time
import uuid
import dma_gpu_guard


class IdleTransition:
    def __init__(self, required=3):
        self.seen_busy = False
        self.idle_samples = 0
        self.required = required

    def observe(self, observation):
        status = observation['status']
        if status == 'busy':
            self.seen_busy = True
        idle = status == 'available' and observation['gpus'] and all(
            gpu['utilization_percent'] < 50 for gpu in observation['gpus'])
        self.idle_samples = self.idle_samples + 1 if self.seen_busy and idle else 0
        return self.idle_samples >= self.required


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--thread', type=uuid.UUID, required=True)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--max-hours', type=float, default=8)
    args = parser.parse_args()
    if not 0 < args.max_hours <= 24:
        parser.error('--max-hours must be in (0, 24]')
    runtime = Path(os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}'))
    lock = (runtime / f'viewflow-gpu-idle-{args.thread}.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.exit(1, 'An idle watcher already owns this thread.\n')
    policy = IdleTransition()
    deadline = time.monotonic() + args.max_hours * 3600
    while time.monotonic() < deadline:
        observation = dma_gpu_guard.sample()
        ready = policy.observe(observation)
        state = {'thread': str(args.thread), 'observation': observation,
                 'seen_busy': policy.seen_busy, 'idle_samples': policy.idle_samples,
                 'status': 'watching', 'starts_tests': False}
        dma_gpu_guard.write_state(args.state, state)
        if ready:
            message = ('GPU idle hook: the host GPU was busy (>=95%) and is now '
                       'below 50% in three consecutive 10-second observations. '
                       'Recheck current occupancy before any performance test. '
                       'This hook has not started tests or stopped workloads.')
            try:
                result = subprocess.run(
                    ['codex', 'queue', '--thread', str(args.thread), '--message', message],
                    capture_output=True, text=True, timeout=30)
                state['status'] = 'queued' if result.returncode == 0 else 'queue-failed'
                state['queue_exit'] = result.returncode
            except (OSError, subprocess.TimeoutExpired) as error:
                # No retry: a timeout may already have delivered the notice.
                state['status'] = 'queue-unconfirmed'
                state['error_type'] = type(error).__name__
            dma_gpu_guard.write_state(args.state, state)
            return
        time.sleep(10)
    dma_gpu_guard.write_state(args.state, {'status': 'expired', 'thread': str(args.thread)})


if __name__ == '__main__':
    main()
