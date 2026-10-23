#!/usr/bin/env python3
"""Read-only NVIDIA occupancy observation; never starts tests or stops workloads."""
import argparse,json,os,subprocess,time
from pathlib import Path

def sample(run=subprocess.run):
 result={'sampled_unix_ns':time.time_ns(),'status':'unknown','threshold_percent':95,'gpus':[]}
 try:
  p=run(['nvidia-smi','--query-gpu=index,utilization.gpu','--format=csv,noheader,nounits'],capture_output=True,text=True,timeout=3,check=True)
  for line in p.stdout.splitlines():
   if not line.strip():continue
   index,value=[v.strip() for v in line.split(',')]
   value=float(value)
   if not 0<=value<=100:raise ValueError('invalid utilization')
   result['gpus'].append({'index':int(index),'utilization_percent':value})
  if not result['gpus']:raise ValueError('no GPU utilization returned')
  result['status']='busy' if any(g['utilization_percent']>=95 for g in result['gpus']) else 'available'
 except Exception as error:result['reason']=str(error)
 return result

def write_state(path,result):
 path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
 temporary=path.with_name(path.name+'.tmp-'+str(os.getpid()))
 temporary.write_text(json.dumps(result,indent=2)+'\n');os.replace(temporary,path)

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--state',type=Path,required=True);p.add_argument('--watch',action='store_true');a=p.parse_args()
 while True:
  result=sample();write_state(a.state,result)
  if not a.watch:print(json.dumps(result));return
  time.sleep(1)
if __name__=='__main__':main()
