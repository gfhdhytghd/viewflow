import pathlib,subprocess,time,threading,os
label='4k-scratch-active-udp';errors=[]
def probe():
 try:
  p=pathlib.Path('/tmp/viewflow-integrated-pair/source-'+label+'.log');until=time.monotonic()+60
  while time.monotonic()<until:
   if p.exists() and 'GPU fixture-marker atlas_frame=4 ' in p.read_text():break
   time.sleep(.1)
  else:raise RuntimeError('no owned fixture frame')
  time.sleep(3)
  env=os.environ.copy();env.update(VIEWFLOW_PROBE_PORT='49101',VIEWFLOW_PROBE_PAIRS='24',VIEWFLOW_PROBE_PAUSE='.1')
  r=subprocess.run(['python3','/tmp/viewflow-run-udp-burst.py','active'],env=env)
  if r.returncode:raise RuntimeError('active UDP probe failed')
 except Exception as e:errors.append(str(e));print('probe_error',e,flush=True)
t=threading.Thread(target=probe);t.start()
env=os.environ.copy();env.update(VIEWFLOW_OBSERVE_FRAMES='1',VIEWFLOW_ALPHA_COPY_PROFILE='1',VIEWFLOW_ALPHA_OUTPUT_COPY='0',VIEWFLOW_TRIAL_GPU_TIMINGS='all',VIEWFLOW_GPU_TILE_COPY='0',VIEWFLOW_QUIC_POLL='1')
r=subprocess.run(['python3','/tmp/viewflow-full-resolution-trial.py',label],env=env);t.join();print('trial',r.returncode,'errors',errors,flush=True)
if r.returncode or errors:raise SystemExit(1)
