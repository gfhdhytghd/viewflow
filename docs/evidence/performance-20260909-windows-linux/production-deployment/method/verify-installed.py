from pathlib import Path
import subprocess,base64,json,hashlib,shutil
R=Path('/home/wilf/data/viewflow');B=Path(__file__).resolve().parent.parent;s=json.loads((B/'method/install-state.json').read_text());assert s['installed']
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert all(sha(x['target'])==sha(x['source'])==x['after'] for x in s['linux_files'])
assert sha(s['control']['path'])==s['control']['after']
windows=r'''[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$native='C:\Users\wilf\Viewflow\desktop-test\viewflow_windows_reverse.exe';$status=& $native --performance-status|ConvertFrom-Json;if($LASTEXITCODE){throw 'native status failed'};[pscustomobject]@{hash=(Get-FileHash $native).Hash;status=$status;receive_hash=(Get-FileHash 'C:\Users\wilf\Viewflow\desktop-test\receive.json').Hash;main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString();streams=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq $native -and $_.CommandLine -notmatch '--performance-status'}|Select-Object ProcessId,ExecutablePath)}|ConvertTo-Json -Depth 5'''
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(windows.encode('utf-16le')).decode()],capture_output=True,check=True,timeout=30);w=json.loads(r.stdout)
assert w['hash']==s['windows']['hash'] and w['receive_hash']==s['windows']['receive_hash'] and w['main']=='Ready' and not w['streams'] and w['status']['mode']=='frame-rate'
linux=json.loads((B/'method/linux-before.json').read_text())
for name in ['desktop-source.json','windows-input-source.json']:assert sha(Path.home()/'.config/viewflow'/name)==linux[name]['sha256']
services=subprocess.run(['systemctl','--user','show','viewflow-desktop.service','viewflow-windows-input.service','-p','Id','-p','ActiveState','-p','SubState'],capture_output=True,text=True,check=True).stdout;assert services==linux['services']
monitors=json.loads(subprocess.check_output(['hyprctl','-j','monitors','all']));fields=['name','width','height','x','y','scale','transform','disabled'];geom=lambda a:sorted(tuple(x[k] for k in fields) for x in a);assert geom(monitors)==geom(s['monitors_before'])
info=subprocess.run(['quickshell','log','--id','hna6pv1lt','--tail','30','--rules','*.warning=false'],capture_output=True,text=True,check=True).stdout
assert 'Configuration Loaded' in info;(B/'method/quickshell-info.log').write_text(info)
warnings=subprocess.run(['quickshell','log','--id','hna6pv1lt','--tail','40'],capture_output=True,text=True,check=True).stdout;(B/'method/quickshell-tail.log').write_text(warnings)
assert 'ViewflowPerformanceSelector.qml' not in warnings and 'ViewflowPerformanceControl.qml' not in warnings
ui=Path('/home/wilf/.config/HyprV/quickshell');lint=subprocess.run(['qmllint','-I','/usr/lib/qt6/qml',str(ui/'ViewflowPerformanceControl.qml'),str(ui/'ViewflowPerformanceSelector.qml')],capture_output=True,text=True);(B/'method/qmllint.log').write_text(lint.stdout+lint.stderr);assert lint.returncode==0
verification={'windows':w,'linux_services':services,'monitors':monitors,'ui_files_match':True,'qml_lint_exit':lint.returncode,'quickshell_reload_seen':True,'quickshell_note':'The unfiltered tail includes supplementaryInfoVisible binding-loop warnings in unchanged shell.qml; no warning names the performance components. This is configuration verification, not physical button acceptance.'}
(B/'method/verified-installed.json').write_text(json.dumps(verification,indent=2)+'\n')
for path in ['tools/viewflow-reverse-performance.py','tools/quickshell/viewflow-reverse-performance.sh','tools/quickshell/ViewflowPerformanceControl.qml','tools/quickshell/ViewflowPerformanceSelector.qml','docs/reverse-performance.md']:
 dest=B/'source'/path;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(R/path,dest)
print('installed binary, controls, configuration, services and topology verified')
