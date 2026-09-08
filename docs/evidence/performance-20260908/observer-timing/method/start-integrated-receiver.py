import pathlib,subprocess,base64,time,os
root=pathlib.Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
def ps(s):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell.exe','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=30)
 return r.returncode,r.stdout.decode(errors='replace')
code,out=ps("& '"+root+"\\target\\release\\vf-media-peer.exe' validate-receive --config '"+root+"\\isolated-receive.json'; exit $LASTEXITCODE")
print('config',code,out,flush=True)
if code:raise SystemExit(code)
args='"'+root+'\\target\\release\\vf-media-peer.exe" "'+root+'\\isolated-receive.json" "'+root+'"'
s="$ErrorActionPreference='Stop'; $name='ViewflowPerf-IntegratedReceiver'; if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'isolated receiver task already exists'}; $principal=(Get-ScheduledTask -TaskName 'ViewflowMain-Active').Principal; $action=New-ScheduledTaskAction -Execute '"+root+"\\isolated-receiver-runner.exe' -Argument '"+args+"' -WorkingDirectory '"+root+"'; Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)) | Out-Null; Start-ScheduledTask -TaskName $name"
if os.environ.get('VIEWFLOW_TRIAL_NOBLUR')=='1':s=s.replace('isolated-receiver-runner.exe','isolated-receiver-runner-noblur.exe')
if os.environ.get('VIEWFLOW_TRIAL_NO_COALESCE')=='1':s=s.replace('isolated-receiver-runner.exe','isolated-receiver-runner-nocoalesce.exe')
if os.environ.get('VIEWFLOW_TRIAL_STABLE_SWAPCHAIN')=='1':s=s.replace('isolated-receiver-runner.exe','isolated-receiver-runner-stable-swapchain.exe')
if os.environ.get('VIEWFLOW_TRIAL_SWAPCHAIN')=='1':s=s.replace('isolated-receiver-runner.exe','isolated-receiver-runner-swapchain.exe')
if os.environ.get('VIEWFLOW_TRIAL_EXPLICIT_COMMIT')=='1':s=s.replace('isolated-receiver-runner.exe','isolated-receiver-runner-explicit.exe')
if os.environ.get('VIEWFLOW_TRIAL_UNSHARED_BLUR')=='1':s=s.replace('isolated-receiver-runner.exe','isolated-receiver-runner-unshared-blur.exe')
if os.environ.get('VIEWFLOW_TRIAL_NATIVE_ALPHA_BASELINE')=='1':s=s.replace('isolated-receiver-runner.exe','isolated-receiver-runner-alpha-baseline.exe')
if os.environ.get('VIEWFLOW_QUIC_SOCKET_TRACE')=='1':s=s.replace('isolated-receiver-runner.exe','isolated-receiver-runner-socket-trace.exe')
if os.environ.get('VIEWFLOW_QUIC_POLL')=='1':s=s.replace('isolated-receiver-runner.exe','isolated-receiver-runner-quic-poll.exe')
if os.environ.get('VIEWFLOW_TRIAL_GPU_PRIORITY') in ('0','7'):
 s=s.replace('isolated-receiver-runner-socket-trace.exe','isolated-receiver-runner-gpu-priority-'+os.environ['VIEWFLOW_TRIAL_GPU_PRIORITY']+'.exe')
code,out=ps(s);print('start',code,out,flush=True)
if code:raise SystemExit(code)
for _ in range(20):
 time.sleep(1)
 code,out=ps("if(Test-Path '"+root+"\\isolated-receiver-stderr.log'){Get-Content '"+root+"\\isolated-receiver-stderr.log' -Tail 5}")
 if 'atlas-peer-listening' in out:print(out,flush=True);break
else:print('No listener observation yet; inspect existing task, do not restart',flush=True)
