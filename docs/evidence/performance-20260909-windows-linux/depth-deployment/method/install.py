"""One-shot upgrade from the verified 875E build to the qualified canonical VPL build."""
from pathlib import Path
import subprocess,json,hashlib,base64,datetime,importlib.util,shutil
b=Path(__file__).resolve().parent.parent;r=Path('/home/wilf/data/viewflow');parent=b.parent
old='875E56F9E746B5DAEA37814DC67C54495A9B313CD6F0EB6B2652A59F057F42FE'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save(v):(b/'method/install-state.json').write_text(json.dumps(v,indent=2)+'\n')
def ps(script,timeout=40):
 p=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+script).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 if p.returncode:raise RuntimeError((p.returncode,(p.stdout+p.stderr).decode(errors='replace')))
 return json.loads(p.stdout)
def linux():
 paths=[Path.home()/'.config/viewflow'/x for x in ['desktop-source.json','windows-input-source.json','reverse-performance.json']]
 paths += [Path.home()/'.config/HyprV/quickshell'/x for x in ['ViewflowPerformanceControl.qml','ViewflowPerformanceSelector.qml','scripts/viewflow-reverse-performance.sh']]
 return {'files':{str(p):sha(p) for p in paths},'services':subprocess.check_output(['systemctl','--user','show','viewflow-desktop.service','viewflow-windows-input.service','-p','Id','-p','ActiveState','-p','SubState'],text=True),'monitors':json.loads(subprocess.check_output(['hyprctl','-j','monitors','all']))}
def geom(x):return sorted(tuple(m[k] for k in ['name','width','height','x','y','scale','transform','disabled']) for m in x)
assert not (b/'method/install-state.json').exists(),'installer already attempted; inspect existing state before any retry'
manifest=json.loads((parent/'root-depth/method/source-sha256.json').read_text());assert manifest==json.loads((parent/'root-depth/method/remote-source-sha256.json').read_text());assert all(sha(r/p)==h for p,h in manifest.items())
assert '100% tests passed, 0 tests failed out of 6' in (parent/'root-depth/method/build.log').read_text()
assert json.loads((parent/'lifecycle-root-depth/runs/root-depth/summary.json').read_text())['qualified']
quality=json.loads((parent/'depth-quality/method/results.json').read_text());assert quality['results']['1']['frames']==quality['results']['2']['frames']==90
for label in ['root-depth-frame-a1','root-depth-latency-b1','root-depth-latency-b2','root-depth-frame-a2']:
 assert json.loads((parent/'transport/runs'/label/'summary.json').read_text())['run_qualified']
 assert 'encoder_backend selected=vpl vendor=32902 forced=0' in (parent/'transport/runs'/label/'source.log').read_text(errors='replace')
native=next(x for x in json.loads((parent/'root-depth/method/build-binaries.json').read_text()) if x['path'].endswith('viewflow_windows_reverse.exe'))
s={'stamp':datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'),'qualified_source_files':len(manifest),'native':native,'old_hash':old,'linux_before':linux(),'installed':False};save(s)
payload=base64.b64encode(json.dumps({'source':native['path'],'hash':native['hash'],'old':old,'stamp':s['stamp']}).encode()).decode()
script=r'''[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__'))|ConvertFrom-Json
$target='C:\Users\wilf\Viewflow\desktop-test\viewflow_windows_reverse.exe';$receive='C:\Users\wilf\Viewflow\desktop-test\receive.json';$mode=Join-Path (Split-Path $target) 'reverse-performance-mode'
if((Get-FileHash $p.source).Hash -ne $p.hash -or (Get-FileHash $target).Hash -ne $p.old){throw 'native identity changed'}
if((Get-ScheduledTask 'ViewflowMain-Active').State.ToString() -ne 'Ready'){throw 'main session is running'}
if(@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq $target -or $_.ExecutablePath -like '*reverse-root-depth-20260909*' -or $_.ExecutablePath -like '*reverse-lifecycle-root-depth-20260909*' -or $_.ExecutablePath -like '*reverse-transport-20260909*'}).Count){throw 'native or benchmark is still running'}
$before=@{receive=(Get-FileHash $receive).Hash;mode=(Get-FileHash $mode).Hash;runtime=(Get-FileHash 'C:\Windows\System32\libvpl.dll').Hash;depth_user=[Environment]::GetEnvironmentVariable('VIEWFLOW_REVERSE_VPL_DEPTH','User');depth_machine=[Environment]::GetEnvironmentVariable('VIEWFLOW_REVERSE_VPL_DEPTH','Machine');encoder_user=[Environment]::GetEnvironmentVariable('VIEWFLOW_REVERSE_ENCODER','User');encoder_machine=[Environment]::GetEnvironmentVariable('VIEWFLOW_REVERSE_ENCODER','Machine')}
if($before.encoder_user -notin @($null,'','auto') -or $before.encoder_machine -notin @($null,'','auto')){throw 'existing explicit encoder override needs inspection'}
if($before.depth_user -notin @($null,'','2') -or $before.depth_machine -notin @($null,'','2')){throw 'existing depth override needs inspection'}
$backup='C:\Users\wilf\Viewflow\performance-depth-backup-'+$p.stamp;if(Test-Path $backup){throw 'backup already exists'};New-Item -ItemType Directory $backup|Out-Null
Copy-Item $target (Join-Path $backup 'viewflow_windows_reverse.exe');$temp=$target+'.'+$p.stamp+'.tmp';$replaced=$false
try{
 Copy-Item $p.source $temp;if((Get-FileHash $temp).Hash -ne $p.hash){throw 'staged binary hash mismatch'}
 [IO.File]::Replace($temp,$target,[NullString]::Value);$replaced=$true
 $status=& $target --performance-status|ConvertFrom-Json;if($LASTEXITCODE -ne 0 -or $status.schema -ne 1){throw 'installed native status failed'}
 if((Get-FileHash $target).Hash -ne $p.hash -or (Get-FileHash $receive).Hash -ne $before.receive -or (Get-FileHash $mode).Hash -ne $before.mode){throw 'post-install files mismatch'}
 [pscustomobject]@{target=$target;hash=(Get-FileHash $target).Hash;backup=$backup;backup_hash=(Get-FileHash (Join-Path $backup 'viewflow_windows_reverse.exe')).Hash;status=$status;before=$before;receive_hash=(Get-FileHash $receive).Hash;mode_hash=(Get-FileHash $mode).Hash;main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString();streams=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq $target}|Select-Object ProcessId,ExecutablePath)}|ConvertTo-Json -Depth 6
}catch{
 if($replaced){$rollback=$target+'.rollback.tmp';Copy-Item (Join-Path $backup 'viewflow_windows_reverse.exe') $rollback;[IO.File]::Replace($rollback,$target,[NullString]::Value)}
 throw
}finally{if(Test-Path $temp){Remove-Item $temp}}
'''.replace('__PAYLOAD__',payload)
local=b/'method/install-windows.ps1';local.write_text(script);remote=r'C:\Users\wilf\Viewflow\performance-depth-install-'+s['stamp']+'.ps1'
subprocess.run(['scp','-q',str(local),'wilf@172.16.105.70:'+remote.replace('\\','/')],check=True,timeout=30)
completed=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',remote],capture_output=True,timeout=45)
(b/'method/install.stdout.log').write_bytes(completed.stdout);(b/'method/install.stderr.log').write_bytes(completed.stderr)
assert completed.returncode==0,(completed.returncode,completed.stderr.decode(errors='replace'));s['windows']=json.loads(completed.stdout);s['installed']=True;save(s)
assert s['windows']['hash']==native['hash'] and s['windows']['backup_hash']==old and not s['windows']['streams'] and s['windows']['main']=='Ready'
spec=importlib.util.spec_from_file_location('vf_control',r/'tools/viewflow-reverse-performance.py');control=importlib.util.module_from_spec(spec);spec.loader.exec_module(control)
config=json.loads((Path.home()/'.config/viewflow/reverse-performance.json').read_text());before=control.request(config);s['mode_before']=before;s['mode_roundtrip']=[];save(s)
try:
 for mode in ['latency','frame-rate']:
  result=control.request(config,mode);assert result['mode']==mode and not result['restarted'];s['mode_roundtrip'].append(result);save(s)
finally:s['mode_restored']=control.request(config,before['mode']);save(s)
s['linux_after']=linux();assert s['linux_before']['files']==s['linux_after']['files'] and s['linux_before']['services']==s['linux_after']['services'] and geom(s['linux_before']['monitors'])==geom(s['linux_after']['monitors'])
s['windows_after']=ps(r"$native='C:\Users\wilf\Viewflow\desktop-test\viewflow_windows_reverse.exe';$status=& $native --performance-status|ConvertFrom-Json;if($LASTEXITCODE){throw 'native status failed'};[pscustomobject]@{hash=(Get-FileHash $native).Hash;mode_hash=(Get-FileHash 'C:\Users\wilf\Viewflow\desktop-test\reverse-performance-mode').Hash;receive_hash=(Get-FileHash 'C:\Users\wilf\Viewflow\desktop-test\receive.json').Hash;main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString();status=$status;streams=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq $native}|Select-Object ProcessId,ExecutablePath)}|ConvertTo-Json -Depth 5")
w=s['windows_after'];assert w['hash']==native['hash'] and w['mode_hash']==s['windows']['mode_hash'] and w['receive_hash']==s['windows']['receive_hash'] and w['status']['mode']==before['mode'] and not w['streams'] and w['main']=='Ready'
s['verified']=True;save(s)
for path in ['docs/reverse-performance.md','platform/windows-reverse/vpl/README.viewflow.md']:
 dest=b/'source'/path;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/path,dest)
print('VPL core installed and verified',native['hash'])
