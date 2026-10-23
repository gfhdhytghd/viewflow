import subprocess,base64,time,select,json
cmd=['ssh','-T','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24','C:/Users/wilf/Viewflow/fusion-20261007/build-banks/Release/viewflow_shared_probe.exe --clock']
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0)
def readline():
 if not select.select([p.stdout],[],[],10)[0]:raise TimeoutError('clock exchange stalled')
 line=p.stdout.readline()
 if not line:raise RuntimeError('clock responder exited')
 return line
try:
 if readline().strip()!=b'READY':raise RuntimeError('clock responder banner')
 samples=[]
 for i in range(100):
  start=time.clock_gettime_ns(time.CLOCK_MONOTONIC);p.stdin.write(b't\n');p.stdin.flush()
  tick,freq=map(int,readline().split());end=time.clock_gettime_ns(time.CLOCK_MONOTONIC)
  guest=tick*1000000000//freq
  samples.append({'host_start_ns':start,'host_end_ns':end,'guest_ns':guest,'rtt_ns':end-start,'offset_low_ns':start-guest,'offset_high_ns':end-guest})
  time.sleep(.01)
 best=min(samples,key=lambda s:s['rtt_ns'])
 result={'clock':'CLOCK_MONOTONIC vs Windows QPC','samples':len(samples),'best':best,'rtt_p50_ms':sorted(x['rtt_ns']/1e6 for x in samples)[len(samples)//2],'uncertainty_ms':best['rtt_ns']/2e6,'offset_mid_ns':(best['offset_low_ns']+best['offset_high_ns'])//2}
 print(json.dumps(result,indent=2))
finally:
 p.stdin.close()
 try:p.wait(timeout=5)
 except subprocess.TimeoutExpired:p.terminate();p.wait()
