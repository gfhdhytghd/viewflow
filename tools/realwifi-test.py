#!/usr/bin/env python3
"""Run already-built owned two-host fixtures, sequentially, over explicit Wi-Fi IPs.

Build instructions and dependency provenance are in docs/weak-network.md.
Never builds during measurement. Never touches production apps or qdiscs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess as sp
import threading
import time

SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10']
TEST = 'atlas_session::realwifi_test::owned_wifi_'


def quantiles(values):
    values = sorted(values)
    return [values[int((len(values)-1)*p)] for p in (.5, .95, .99)] if values else []


def station():
    return sp.check_output(['iw','dev','wlan0','station','get','2a:73:07:17:ce:79'],text=True)


def run(args, variant, mode, fec):
    binary = str(Path(getattr(args, variant + '_sender')).resolve())
    receiver = getattr(args, variant + '_receiver')
    before = station()
    remote_env = dict(VF_WIFI_SECONDS=str(args.seconds), VF_WIFI_BIND='10.42.0.125:45872', VIEWFLOW_FEC=fec)
    command = ('echo $$ > ' + shlex.quote(args.remote_dir+'/receiver.pid') + '; exec env ' +
               ' '.join(shlex.quote(k+'='+v) for k,v in remote_env.items()) + ' ' +
               shlex.quote(receiver) + ' '+TEST+'receiver --ignored --exact --nocapture')
    rx = sp.Popen(SSH+[args.host,command],stdout=sp.PIPE,stderr=sp.STDOUT,text=True)
    lines = []
    ready = threading.Event()
    def collect():
        for line in rx.stdout:
            lines.append(line)
            if 'WIFI_READY' in line:
                ready.set()
    thread=threading.Thread(target=collect)
    thread.start()
    try:
        if not ready.wait(20):
            raise RuntimeError('receiver not ready: '+''.join(lines))
        env = dict(os.environ, VF_WIFI_SECONDS=str(args.seconds),VF_WIFI_MODE=mode,
                   VF_WIFI_BIND='10.42.0.1:0', VF_WIFI_PEER='10.42.0.125:45872',VIEWFLOW_FEC=fec)
        start=time.time()
        tx=sp.run([binary,TEST+'sender','--ignored','--exact','--nocapture'],env=env,
                  capture_output=True,text=True,timeout=args.seconds+40)
        rx.wait(timeout=20)
        thread.join()
        after=station()
        assert tx.returncode==0,(tx.stdout[-3000:],tx.stderr[-3000:])
        assert rx.returncode==0,''.join(lines)[-3000:]
        sender=json.loads(next(line[len('WIFI_SENDER '):] for line in tx.stdout.splitlines() if line.startswith('WIFI_SENDER ')))
        received=json.loads(next(line[len('WIFI_RECEIVER '):] for line in lines if line.startswith('WIFI_RECEIVER ')))
        delays=sender.pop('submit_to_disposition_ms')
        dispositions=sender.pop('dispositions')
        trace=sender.pop('target_trace_s_kbps_fps')
        gaps=received.pop('gaps_ms')
        row=dict(variant=variant,mode=mode,fec=fec,unix_start=start,
                 sender_sha256=hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
                 receiver_sha256=sp.check_output(SSH+[args.host,'shasum -a 256 '+shlex.quote(receiver)],text=True).split()[0],
                 seconds_requested=args.seconds,sender=sender,receiver=received,
                 feedback_ms_p50_p95_p99=quantiles(delays),feedback_max_ms=max(delays,default=0),
                 dispositions={v:dispositions.count(v) for v in sorted(set(dispositions))},
                 gap_ms_p50_p95_p99=quantiles(gaps),gap_max_ms=max(gaps,default=0),
                 stalls_over100ms=[g for g in gaps if g>100],
                 target_kbps_min_max=[min(t[1] for t in trace),max(t[1] for t in trace)] if trace else [],
                 station_before=before,station_after=after,
                 socket_config=[line.strip() for line in lines+tx.stderr.splitlines() if 'WIFI_SOCKET' in line])
        assert sender['seconds'] >= args.seconds,row
        assert sender['error'] is None,row
        assert received['error'] is None,row
        assert received['complete']==row['dispositions'].get('Some(Committed)',0),row
        return row
    finally:
        if rx.poll() is None:
            # Kill only the PID created by this invocation's remote shell.
            sp.run(SSH+[args.host,'kill "$(cat '+shlex.quote(args.remote_dir+'/receiver.pid')+')"'],capture_output=True)
            rx.terminate()
        rx.wait()
        thread.join(timeout=2)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--host',default='linhaikuo@10.42.0.125')
    p.add_argument('--remote-dir',default='/Volumes/MoveDATA/viewflow-wifi-test')
    p.add_argument('--stock-sender',required=True)
    p.add_argument('--stock-receiver',required=True)
    p.add_argument('--deep-sender',required=True)
    p.add_argument('--deep-receiver',required=True)
    p.add_argument('--seconds',type=int,default=60)
    p.add_argument('--output',default='docs/evidence/realwifi-media.json')
    p.add_argument('--smoke',action='store_true')
    a=p.parse_args()
    matrix=[('stock','auto','auto'),('deep','auto','auto'),('stock','auto','off'),('deep','auto','off'),
            ('stock','high_quality','auto'),('stock','save_bandwidth','auto')]
    if a.smoke:
        matrix=matrix[:1]
    rows=[]
    for variant,mode,fec in matrix:
        row=run(a,variant,mode,fec)
        rows.append(row)
        Path(a.output).write_text(json.dumps(rows,indent=2)+'\n')
        print(variant,mode,fec,'complete',row['receiver']['complete'],'p95',row['feedback_ms_p50_p95_p99'],flush=True)


if __name__=='__main__':
    main()
