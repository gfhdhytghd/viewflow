"""Install the qualified reverse binary and controls; retain existing sessions."""
from pathlib import Path
import base64,hashlib,json,os,shutil,subprocess,tempfile,datetime
R=Path('/home/wilf/data/viewflow');B=Path(__file__).resolve().parent.parent
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
backup=Path.home()/'.local/share/viewflow'/('performance-reverse-backup-'+stamp);backup.mkdir(parents=True)
state={'stamp':stamp,'backup':str(backup),'linux_files':[]}
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save():(B/'method/install-state.json').write_text(json.dumps(state,indent=2)+'\n')
def ps(script):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],capture_output=True,timeout=45)
 if r.returncode:raise RuntimeError((r.stdout+r.stderr).decode(errors='replace'))
 return json.loads(r.stdout)
def atom(path,data,mode):
 fd,name=tempfile.mkstemp(prefix='.'+path.name+'.reverse-',dir=path.parent)
 try:
  with os.fdopen(fd,'wb') as f:os.fchmod(f.fileno(),mode);f.write(data);f.flush();os.fsync(f.fileno())
  Path(name).replace(path)
 finally:Path(name).unlink(missing_ok=True)
build=B.parent/'root-performance-v2';sources=json.loads((build/'method/source-sha256.json').read_text());assert sources==json.loads((build/'method/remote-source-sha256.json').read_text());assert all(sha(R/p)==h for p,h in sources.items())
assert '100% tests passed, 0 tests failed out of 6' in (build/'method/build.log').read_text()
assert json.loads((B.parent/'lifecycle-v3/runs/root-v2/summary.json').read_text())['qualified']
for label in ['root-frame-a1','root-latency-b1','root-latency-b2','root-frame-a2']:assert json.loads((B.parent/'transport/runs'/label/'summary.json').read_text())['run_qualified']
native=next(x for x in json.loads((build/'method/build-binaries.json').read_text()) if x['path'].endswith('viewflow_windows_reverse.exe'))
winbefore=json.loads((B/'method/windows-before.json').read_text());linuxbefore=json.loads((B/'method/linux-before.json').read_text())
for name in ['desktop-source.json','windows-input-source.json']:assert sha(Path.home()/'.config/viewflow'/name)==linuxbefore[name]['sha256']
state['monitors_before']=json.loads(subprocess.check_output(['hyprctl','-j','monitors','all']));save()
ui=Path('/home/wilf/.config/HyprV/quickshell')
files=[(R/'tools/quickshell/viewflow-reverse-performance.sh',ui/'scripts/viewflow-reverse-performance.sh',0o755),(R/'tools/quickshell/ViewflowPerformanceSelector.qml',ui/'ViewflowPerformanceSelector.qml',0o644),(R/'tools/quickshell/ViewflowPerformanceControl.qml',ui/'ViewflowPerformanceControl.qml',0o644)]
for source,target,mode in files:
 index=len(state['linux_files']);old=sha(target) if target.exists() else None
 if old is not None:shutil.copy2(target,backup/f'file-{index}')
 state['linux_files'].append({'source':str(source),'target':str(target),'before':old,'after':sha(source),'mode':mode,'backup':str(backup/f'file-{index}') if old else None})
control=Path.home()/'.config/viewflow/reverse-performance.json';control_bytes=(json.dumps({'ssh_host':'wilf@172.16.105.70','native':winbefore['native']},indent=2)+'\n').encode();old=sha(control) if control.exists() else None
if old:shutil.copy2(control,backup/'control.json')
state['control']={'path':str(control),'before':old,'after':hashlib.sha256(control_bytes).hexdigest(),'backup':str(backup/'control.json') if old else None};save()
payload=base64.b64encode(json.dumps({'source':native['path'],'hash':native['hash'],'target':winbefore['native'],'old_hash':winbefore['hash'],'receive_hash':winbefore['receive_hash'],'stamp':stamp}).encode()).decode()
script=r'''[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__'))|ConvertFrom-Json
if((Get-FileHash $p.source).Hash -ne $p.hash -or (Get-FileHash $p.target).Hash -ne $p.old_hash){throw 'native identity changed before install'}
if(@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq $p.target}).Count){throw 'native source is running; install has not started'}
if((Get-ScheduledTask 'ViewflowMain-Active').State.ToString() -ne 'Ready'){throw 'main session changed; install has not started'}
$receive='C:\Users\wilf\Viewflow\desktop-test\receive.json'
if((Get-FileHash $receive).Hash -ne $p.receive_hash){throw 'receive configuration changed'}
$backup='C:\Users\wilf\Viewflow\performance-reverse-backup-'+$p.stamp
if(Test-Path $backup){throw 'backup exists'};New-Item -ItemType Directory $backup|Out-Null
Copy-Item $p.target (Join-Path $backup 'viewflow_windows_reverse.exe')
$modeFile=Join-Path (Split-Path -Parent $p.target) 'reverse-performance-mode';$hadMode=Test-Path $modeFile;$mode='frame-rate'
if($hadMode){Copy-Item $modeFile (Join-Path $backup 'reverse-performance-mode');$oldMode=(Get-Content $modeFile -Raw).Trim();if($oldMode -in @('frame-rate','latency')){$mode=$oldMode}}
$temp=$p.target+'.'+$p.stamp+'.tmp';$modeTemp=$modeFile+'.'+$p.stamp+'.tmp';$replaced=$false;$modeWritten=$false
try {
 Copy-Item $p.source $temp;if((Get-FileHash $temp).Hash -ne $p.hash){throw 'staged native mismatch'}
 [IO.File]::Replace($temp,$p.target,[NullString]::Value);$replaced=$true
 [IO.File]::WriteAllText($modeTemp,$mode+"`n",[Text.UTF8Encoding]::new($false))
 if($hadMode){[IO.File]::Replace($modeTemp,$modeFile,[NullString]::Value)}else{[IO.File]::Move($modeTemp,$modeFile)};$modeWritten=$true
 $status=& $p.target --performance-status|ConvertFrom-Json;if($LASTEXITCODE -ne 0 -or $status.schema -ne 1 -or $status.mode -ne $mode){throw 'installed settings check failed'}
 if((Get-FileHash $p.target).Hash -ne $p.hash -or (Get-FileHash $receive).Hash -ne $p.receive_hash){throw 'post-install identity mismatch'}
 [pscustomobject]@{target=$p.target;hash=(Get-FileHash $p.target).Hash;backup=$backup;status=$status;mode_file=$modeFile;had_mode_file=$hadMode;receive_hash=(Get-FileHash $receive).Hash;main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString();processes=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq $p.target -and $_.CommandLine -notmatch '--performance-status'}|Select-Object ProcessId,ExecutablePath)}|ConvertTo-Json -Depth 5
} catch {
 if($replaced){$restore=$p.target+'.restore';Copy-Item (Join-Path $backup 'viewflow_windows_reverse.exe') $restore;[IO.File]::Replace($restore,$p.target,[NullString]::Value)}
 if($modeWritten){if($hadMode){Copy-Item (Join-Path $backup 'reverse-performance-mode') $modeTemp;[IO.File]::Replace($modeTemp,$modeFile,[NullString]::Value)}else{Remove-Item $modeFile}}
 throw
} finally {if(Test-Path $temp){Remove-Item $temp};if(Test-Path $modeTemp){Remove-Item $modeTemp}}
'''.replace('__PAYLOAD__',payload)
(B/'method/install-windows.ps1').write_text(script);state['windows']=ps(script);save();print('Windows installed and native settings verified',flush=True)
assert state['windows']['main']=='Ready' and not state['windows']['processes']
# Install dependencies before the containing component so Quickshell can reload.
atom(control,control_bytes,0o600)
for row in state['linux_files']:
 target=Path(row['target']);assert (sha(target) if target.exists() else None)==row['before'];atom(target,Path(row['source']).read_bytes(),row['mode'])
state['monitors_after']=json.loads(subprocess.check_output(['hyprctl','-j','monitors','all']))
fields=['name','width','height','x','y','scale','transform','disabled'];geom=lambda rows:sorted(tuple(x[k] for k in fields) for x in rows)
assert geom(state['monitors_before'])==geom(state['monitors_after'])
assert all(sha(row['target'])==row['after'] for row in state['linux_files']) and sha(control)==state['control']['after']
for name in ['desktop-source.json','windows-input-source.json']:assert sha(Path.home()/'.config/viewflow'/name)==linuxbefore[name]['sha256']
state['services_after']=subprocess.run(['systemctl','--user','show','viewflow-desktop.service','viewflow-windows-input.service','-p','Id','-p','ActiveState','-p','SubState'],capture_output=True,text=True,check=True).stdout
assert state['services_after']==linuxbefore['services'];state['installed']=True;save();print('Linux controls installed; configuration, services and monitor geometry verified',flush=True)
