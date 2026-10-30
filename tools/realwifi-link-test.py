#!/usr/bin/env python3
"""Sequential owned UDP matrix; run after all builds finish."""
import argparse
import subprocess as sp, json, time
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host',default='linhaikuo@10.42.0.125')
parser.add_argument('--remote-dir',default='/Volumes/MoveDATA/viewflow-wifi-test')
parser.add_argument('--output',default='docs/evidence/realwifi-raw.json')
args=parser.parse_args()
host=args.host
base=['ssh','-o','BatchMode=yes',host]
probe=args.remote_dir+'/realwifi-probe.py'
rows=[]
for direction in ['linux-mac','mac-linux']:
 for rate in ['20','100','300','burst']:
  common=['--seconds','10']+(['--burst'] if rate=='burst' else ['--rate',rate])
  if direction=='linux-mac':
   rx=sp.Popen(base+['python3',probe,'receive','--bind','10.42.0.125','--peer','10.42.0.1'],stdout=sp.PIPE,stderr=sp.PIPE,text=True)
   tx=['python3','tools/realwifi-probe.py','send','--bind','10.42.0.1','--peer','10.42.0.125']+common
  else:
   rx=sp.Popen(['python3','tools/realwifi-probe.py','receive','--bind','10.42.0.1','--peer','10.42.0.125'],stdout=sp.PIPE,stderr=sp.PIPE,text=True)
   tx=base+['python3',probe,'send','--bind','10.42.0.125','--peer','10.42.0.1']+common
  time.sleep(1)
  before=sp.check_output(['iw','dev','wlan0','station','get','2a:73:07:17:ce:79'],text=True)
  try:
   sent=sp.run(tx,capture_output=True,text=True,timeout=25,check=True)
   out,err=rx.communicate(timeout=10)
   assert rx.returncode==0,(out,err)
   row=dict(direction=direction,rate=rate,sender=json.loads(sent.stdout),receiver=json.loads(out),station_before=before,station_after=sp.check_output(['iw','dev','wlan0','station','get','2a:73:07:17:ce:79'],text=True))
   rows.append(row)
   Path(args.output).write_text(json.dumps(rows,indent=2)+'\n')
   print(direction,rate,row['receiver'],flush=True)
  finally:
   if rx.poll() is None:
    rx.terminate();rx.wait()
