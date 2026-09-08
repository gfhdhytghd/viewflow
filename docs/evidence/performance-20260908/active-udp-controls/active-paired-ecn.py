import pathlib,subprocess,time,threading,os
label='4k-paired-ecn';errors=[]
def probes():
 try:
  p=pathlib.Path('/tmp/viewflow-integrated-pair/source-'+label+'.log');until=time.monotonic()+60
  while time.monotonic()<until:
   if p.exists() and 'GPU fixture-marker atlas_frame=4 ' in p.read_text():break
   time.sleep(.1)
  else:raise RuntimeError('no owned fixture frame')
  jobs=[subprocess.Popen(['python3','/tmp/viewflow-run-paired-udp.py',name,'blocking',port,ecn]) for name,port,ecn in [('paired-ecn0','49101','0'),('paired-ecn2','49102','2')]]
  codes=[p.wait() for p in jobs];assert codes==[0,0],codes
 except Exception as e:errors.append(str(e));print('probe_error',e,flush=True)
t=threading.Thread(target=probes);t.start()
env=dict(os.environ,VIEWFLOW_OBSERVE_FRAMES='0',VIEWFLOW_ALPHA_COPY_PROFILE='1',VIEWFLOW_ALPHA_OUTPUT_COPY='0',VIEWFLOW_TRIAL_GPU_TIMINGS='all',VIEWFLOW_GPU_TILE_COPY='0',VIEWFLOW_QUIC_POLL='0',VIEWFLOW_QUIC_SOCKET_TRACE='1')
r=subprocess.run(['python3','/tmp/viewflow-full-resolution-trial.py',label],env=env);t.join();print('trial_exit',r.returncode,'errors',errors,flush=True)
if r.returncode or errors:raise SystemExit(1)
