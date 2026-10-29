#!/usr/bin/env python3
"""Owned NVENC/atlas experiment; all shaping and endpoints stay in a private netns.
Usage: tools/weak-network-test.py [--seconds 30] [--output PATH]
Requires cargo, unshare, iproute2 (ip/tc), FFmpeg development libraries and NVENC.
No desktop, input devices, focus changes or system interface changes are used.
"""
import argparse
import datetime
import json
import os
import signal
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
def stable_target_time(row):
    """First 2s within +/-20% of the last-5s median; burst starts at recovery."""
    import statistics
    trace = row['target_trace_s_kbps_fps']
    final = [v[1] for v in trace if v[0] >= row['seconds'] - 5]
    if not final:
        return None
    median = statistics.median(final)
    since = None
    start = 20 if row['scenario'] == 'burst' else 0
    for t, rate, _ in trace:
        if t < start:
            continue
        if abs(rate - median) <= median * .2:
            if since is None:
                since = t
            if t - since >= 2:
                return round(since - start, 3)
        else:
            since = None
    return None


TEST = 'atlas_session::netem_test::owned_netem_session'
SCENARIOS = [('clean', 'auto'), ('wifi1', 'auto'), ('wifi5', 'auto'),
             ('cap20', 'auto'), ('cap8', 'auto'), ('burst', 'auto'),
             ('cap20', 'high_quality'), ('cap20', 'save_bandwidth')]


def wait_for_other_measurements(record):
    """Do not overlap another worktree's owned netem experiment (60s polls)."""
    while True:
        found = subprocess.run(['pgrep', '-af', 'weak-network-test|netem_session'],
                               text=True, capture_output=True, check=False)
        if found.returncode not in (0, 1):
            raise RuntimeError('pgrep failed: ' + found.stderr.strip())
        active = []
        deferred_launchers = []
        for line in found.stdout.splitlines():
            pid, command = line.split(' ', 1)
            if int(pid) == os.getpid():
                continue
            argv = command.split()
            # Ignore shell source that merely mentions these command names.
            launcher = (len(argv) > 1 and Path(argv[0]).name.startswith('python')
                        and Path(argv[1]).name == 'weak-network-test.py')
            owned_test = (argv and Path(argv[0]).name.startswith('viewflowd-')
                          and TEST in argv)
            if owned_test or (launcher and int(pid) < os.getpid()):
                active.append(line)
            elif launcher:
                # Two launchers can both be waiting between scenarios. Elect
                # the lower PID, rather than waiting forever for each other.
                # An actual test always blocks regardless of launcher priority.
                deferred_launchers.append(line)
        record('UTC ' + datetime.datetime.now(datetime.timezone.utc).isoformat()
               + ' $ pgrep -af "weak-network-test|netem_session"; other measurement processes='
               + str(len(active)))
        for line in active:
            record(line)
        for line in deferred_launchers:
            record('lower-priority launcher (no active test): ' + line)
        if not active:
            return
        print('Waiting for other netem measurement (60s poll)', flush=True)
        time.sleep(60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/evidence/weak-network-netem.txt')
    parser.add_argument('--scenario', choices=[s for s, _ in SCENARIOS[:6]])
    args = parser.parse_args()
    if args.seconds < 30:
        parser.error('each scenario must last at least 30 seconds')
    build = subprocess.run(['cargo', 'test', '-p', 'viewflowd', '--features', 'native-gpu-nvenc',
                            '--lib', TEST, '--no-run', '--message-format=json'],
                           cwd=ROOT, text=True, stdout=subprocess.PIPE, check=True)
    artifacts = [json.loads(line) for line in build.stdout.splitlines()]
    binary = next(a['executable'] for a in artifacts if a.get('reason') == 'compiler-artifact'
                  and a.get('executable') and a['target']['name'] == 'viewflowd')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    with args.output.open('w') as evidence:
        def record(text):
            evidence.write(text + '\n')
            evidence.flush()
        record('Viewflow owned RGBA -> NVENC -> atlas QUIC -> reassembly (no decode/display)')
        record('UTC ' + datetime.datetime.now(datetime.timezone.utc).isoformat())
        record('git ' + subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
               + ' + working tree changes; source SHA256 below')
        import hashlib
        for p in ['tools/weak-network-test.py', 'protocol/viewflow/v1/control.proto',
                  'crates/viewflow-core/src/atlas_pipeline.rs',
                  'crates/viewflowd/src/atlas_netem_test.rs',
                  'crates/viewflowd/src/atlas_session.rs', 'crates/viewflowd/src/atlas_loss.rs',
                  'crates/viewflow-core/src/rate_control.rs', 'crates/viewflowd/src/quality.rs',
                  'crates/viewflowd/src/coded_peer.rs', 'crates/viewflowd/src/gpu_atlas_sender.rs',
                  'crates/viewflowd/src/native_quality.rs',
                  'platform/nvenc-encoder/nvenc_encoder.cpp',
                  'platform/nvenc-encoder/gpu_dmabuf_encoder.cu',
                  'crates/viewflow-transport/src/reassembly.rs', 'Cargo.lock']:
            record(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() + '  ' + p)
        record(hashlib.sha256(Path(binary).read_bytes()).hexdigest() + '  test executable')
        for cmd in [['uname', '-a'], ['tc', '-V'], ['rustc', '--version'],
                    ['nvidia-smi', '--query-gpu=name,driver_version', '--format=csv,noheader']]:
            output = subprocess.run(cmd, capture_output=True, text=True, check=True)
            record('$ ' + ' '.join(cmd) + '\n' + output.stdout.strip())
        for scenario, mode in SCENARIOS:
            if args.scenario and scenario != args.scenario:
                continue
            wait_for_other_measurements(record)
            print(f'Running {scenario}/{mode} ({args.seconds}s)', flush=True)
            env = os.environ.copy()
            env.update(VF_NETEM_PRIVATE='1', VF_NETEM_SCENARIO=scenario,
                       VF_NETEM_MODE=mode, VF_NETEM_SECONDS=str(args.seconds))
            # Fresh namespace per scenario; kernel removes the qdisc on exit.
            cmd = ['unshare', '-rn', 'sh', '-c',
                   'ip link set lo up && "$@"; result=$?; tc -s qdisc show dev lo; exit "$result"',
                   'netem', binary, TEST, '--exact', '--ignored', '--nocapture']
            run = subprocess.Popen(cmd, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
            try:
                stdout, _ = run.communicate(timeout=args.seconds + 90)
            except subprocess.TimeoutExpired:
                os.killpg(run.pid, signal.SIGKILL)
                stdout, _ = run.communicate()
                record(f'\n=== {scenario}/{mode} TIMEOUT ===\n{stdout}')
                raise RuntimeError(f'{scenario}/{mode} timed out; namespace processes stopped') from None
            record(f'\n=== {scenario}/{mode} exit={run.returncode} ===\n{stdout}')
            result = next((json.loads(line.removeprefix('NETEM_RESULT '))
                           for line in stdout.splitlines() if line.startswith('NETEM_RESULT ')), None)
            if run.returncode or result is None:
                raise RuntimeError(f'{scenario}/{mode} failed; see {args.output}')
            result['stable_target_s'] = stable_target_time(result)
            record('NETEM_ANALYSIS ' + json.dumps({k: result[k] for k in
                   ['scenario', 'mode', 'stable_target_s']}))
            rows.append(result)
        header = '| scenario/mode | survived | sent/complete/lost | KF/NACK/repair | UDP/complete Mbps | latency p50/p95/p99 ms | stalls >100ms | target first/final kbps; stable s |'
        lines = [header, '|---|---|---|---|---|---|---|---|']
        for r in rows:
            trace = r['target_trace_s_kbps_fps']
            lines.append(f"| {r['scenario']}/{r['mode']} | {r['survived']} | {r['sent']}/{r['complete']}/{r['frames_lost']} | "
                         f"{r['keyframe_requests']}/{r['nacks']}/{r['repair_datagrams_enqueued']} | "
                         f"{r['udp_tx_mbps']:.2f}/{r['complete_mbps']:.2f} | "
                         + '/'.join(f'{x:.1f}' for x in r['latency_ms'])
                         + f" | {len(r['stall_ms'])} | {trace[0][1]}/{trace[-1][1]}; {r['stable_target_s']} |")
        table = '\n'.join(lines)
        record('\n' + table)
        print(table)
        if any(not r['survived'] or not r['complete'] or r['seconds'] < args.seconds
               or (r['scenario'] == 'burst' and not r['complete_by_10s_phase'][2]) for r in rows):
            raise RuntimeError('scenario failed or ended early; see evidence')
    print(f'Evidence: {args.output}')


if __name__ == '__main__':
    main()
