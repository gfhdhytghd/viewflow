import pathlib,subprocess,base64,sys,time,os
root=pathlib.Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
local=pathlib.Path('/tmp/viewflow-integrated-pair');label=sys.argv[1];variant=sys.argv[2]
def ps(s):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell.exe','-NoProfile','-EncodedCommand',base64.b64encode(("$ProgressPreference='SilentlyContinue'; $ErrorActionPreference='Stop'; "+s).encode('utf-16le')).decode()],capture_output=True,timeout=35)
 if r.returncode:raise RuntimeError(r.stdout.decode(errors='replace')+r.stderr.decode('gb18030',errors='replace'))
 return r.stdout.decode(errors='replace')
ps("if(Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver' -ErrorAction SilentlyContinue){throw 'task already exists'}; Get-ChildItem '"+root+"\\isolated-*.log' | Remove-Item")
subprocess.run(['python3','/tmp/viewflow-start-'+('unbuffered' if variant=='old' else 'integrated')+'-receiver.py'],check=True)
observer=subprocess.Popen(['python3',('/tmp/viewflow-observe-both.py' if os.environ.get('VIEWFLOW_OBSERVE_BOTH')=='1' else '/tmp/viewflow-observe-frames.py'),label]) if os.environ.get('VIEWFLOW_OBSERVE_FRAMES')=='1' else None
with (local/('source-'+label+'.log')).open('w') as log:
 r=subprocess.run(['timeout','--signal=TERM','--kill-after=10s','25s','env','VIEWFLOW_CLIPBOARD=0','VIEWFLOW_ATLAS_TIMINGS=all','VIEWFLOW_GPU_TIMINGS='+os.environ.get('VIEWFLOW_TRIAL_GPU_TIMINGS','1'),'VIEWFLOW_GPU_FIXTURE_MARKER=1',os.environ.get('VIEWFLOW_TRIAL_SOURCE','target/release/vf-media-peer'),'send','--config',str(local/'send.json')],stdout=log,stderr=subprocess.STDOUT,timeout=40)
print('source_exit',r.returncode,flush=True)
if observer is not None:
 observer.wait(timeout=60)
 print('observer_exit',observer.returncode,flush=True)
for attempt in range(40):
 out=ps("$p=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith('"+root+"',[System.StringComparison]::OrdinalIgnoreCase) }); Write-Output $p.Count")
 if out.strip()=='0':break
 time.sleep(1)
else:raise RuntimeError('owned processes remain')
for remote,name in [('isolated-receiver-stderr.log','receiver'),('isolated-receiver-stdout.log','stdout'),('isolated-runner-status.log','runner')]:
 subprocess.run(['scp','-q','-o','BatchMode=yes','wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/'+remote,str(local/(name+'-'+label+'.log'))],check=True)
out=ps("$t=Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver'; if($t.State -eq 'Running'){throw 'task running'}; Unregister-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver' -Confirm:$false; Write-Output 'isolated_processes=0 task_removed=true'")
(local/('cleanup-'+label+'.log')).write_text(out);print(out,flush=True)
print((local/('runner-'+label+'.log')).read_text(),flush=True)
