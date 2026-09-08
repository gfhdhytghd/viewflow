import pathlib,subprocess,base64,time,os
root=pathlib.Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
def ps(s):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell.exe','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=30)
 return r.returncode,r.stdout.decode(errors='replace')+(r.stderr.decode('gb18030',errors='replace') if r.returncode else '')
receiver_exe=root+('\\vf-media-peer-av1.exe' if os.environ.get('VIEWFLOW_TRIAL_RECEIVER_VARIANT')=='av1' else '\\target\\release\\vf-media-peer.exe')
code,out=ps("& '"+receiver_exe+"' validate-receive --config '"+root+"\\isolated-receive.json'; exit $LASTEXITCODE")
print('config',code,out,flush=True)
if code:raise SystemExit(code)
args='"'+receiver_exe+'" "'+root+'\\isolated-receive.json" "'+root+'"'
disabled=os.environ['VIEWFLOW_TRIAL_BINARY_BACKDROP_DISABLED'];assert disabled in ('0','1')
args+=' '+disabled
s="$ErrorActionPreference='Stop'; $name='ViewflowPerf-IntegratedReceiver'; if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'isolated receiver task already exists'}; $principal=(Get-ScheduledTask -TaskName 'ViewflowMain-Active').Principal; $action=New-ScheduledTaskAction -Execute '"+root+"\\isolated-receiver-runner-binary-backdrop.exe' -Argument '"+args+"' -WorkingDirectory '"+root+"'; Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)) | Out-Null; Start-ScheduledTask -TaskName $name"
code,out=ps(s);print('start',code,out,flush=True)
if code:raise SystemExit(code)
for _ in range(20):
 time.sleep(1)
 code,out=ps("if(Test-Path '"+root+"\\isolated-receiver-stderr.log'){Get-Content '"+root+"\\isolated-receiver-stderr.log' -Tail 5}")
 if 'atlas-peer-listening' in out:print(out,flush=True);break
else:print('No listener observation yet; inspect existing task, do not restart',flush=True)
