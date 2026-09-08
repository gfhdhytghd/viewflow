import pathlib,subprocess,base64,time,os,threading,json
root=pathlib.Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip();label='4k-longtail-pktmon'
def ps(s):
 prefix="$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $ErrorActionPreference='Stop'; "
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode((prefix+s).encode('utf-16le')).decode()],capture_output=True,timeout=120)
 print(r.returncode,r.stdout.decode(errors='replace'),flush=True);r.check_returncode();return r.stdout.decode(errors='replace')
def copy(name):subprocess.run(['scp','-q','-o','BatchMode=yes','wilf@172.16.105.70:'+root.replace('\\','/')+'/'+name,'/tmp/viewflow-'+name],check=True)
errors=[]
def trace():
 started=False;filtered=False
 try:
  source=pathlib.Path('/tmp/viewflow-integrated-pair/source-'+label+'.log');until=time.monotonic()+90
  while time.monotonic()<until:
   if source.exists() and 'GPU fixture-marker atlas_frame=4 ' in source.read_text():break
   time.sleep(.25)
  else:raise RuntimeError('no live frame')
  ps("pktmon filter add ViewflowIsolated49073 -t UDP -i 172.16.105.62 -p 49073; if($LASTEXITCODE){exit $LASTEXITCODE}");filtered=True
  ps("pktmon list --json | Out-File -Encoding utf8 '"+root+"\\pktmon-components.json'; $q0=[Diagnostics.Stopwatch]::GetTimestamp(); $utc=[DateTime]::UtcNow.ToFileTimeUtc(); $q1=[Diagnostics.Stopwatch]::GetTimestamp(); @{before_qpc=$q0;filetime=$utc;after_qpc=$q1;frequency=[Diagnostics.Stopwatch]::Frequency} | ConvertTo-Json | Out-File -Encoding utf8 '"+root+"\\pktmon-clock.json'; pktmon start --capture --comp all --pkt-size 64 --file-size 64 --file-name '"+root+"\\longtail-pktmon.etl'; exit $LASTEXITCODE");started=True
  time.sleep(10)
 finally:
  if started:ps('pktmon stop; exit $LASTEXITCODE')
  if filtered:ps('pktmon filter remove ViewflowIsolated49073; exit $LASTEXITCODE')
 if started:
  ps("pktmon etl2txt '"+root+"\\longtail-pktmon.etl' --out '"+root+"\\longtail-pktmon.txt' --timestamp --verbose; if($LASTEXITCODE){exit $LASTEXITCODE}; pktmon etl2pcap '"+root+"\\longtail-pktmon.etl' --out '"+root+"\\longtail-pktmon.pcapng'; exit $LASTEXITCODE")
  for name in ['longtail-pktmon.etl','longtail-pktmon.txt','longtail-pktmon.pcapng','pktmon-components.json','pktmon-clock.json']:copy(name)
def guarded():
 try:trace()
 except Exception as e:errors.append(str(e));print('trace_error',e,flush=True)
t=threading.Thread(target=guarded);t.start()
env=os.environ.copy();env.update(VIEWFLOW_OBSERVE_FRAMES='1',VIEWFLOW_ALPHA_COPY_PROFILE='1',VIEWFLOW_ALPHA_OUTPUT_COPY='0',VIEWFLOW_TRIAL_GPU_TIMINGS='all',VIEWFLOW_QUIC_POLL='1')
r=subprocess.run(['python3','/tmp/viewflow-full-resolution-trial.py',label],env=env)
t.join();print('trial_exit',r.returncode,'trace_errors',errors,flush=True)
if r.returncode or errors:raise SystemExit(1)
