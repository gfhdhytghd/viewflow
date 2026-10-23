from pathlib import Path
import subprocess,base64,hashlib,json
b=Path(__file__).resolve().parent.parent
s="$ErrorActionPreference='Stop';[pscustomobject]@{processes=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -like '*perf-isolated-8e97c1b751fc*'}|Select-Object ProcessId,ExecutablePath);tasks=@(Get-ScheduledTask|Where-Object{$_.TaskName -in @('ViewflowPerf-FullGlassReceiver','ViewflowPerf-FullGlassObserver','ViewflowPerf-CommitRequestProbe','ViewflowPerf-CommitRequestProbeObserver')}|Select-Object TaskName,State);port=@(Get-NetUDPEndpoint -LocalPort 49073 -ErrorAction SilentlyContinue).Count;blur_user=[Environment]::GetEnvironmentVariable('VIEWFLOW_ATLAS_BLUR_SIGMA','User');blur_machine=[Environment]::GetEnvironmentVariable('VIEWFLOW_ATLAS_BLUR_SIGMA','Machine');esrv=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass)}|ConvertTo-Json -Depth 5"
r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,check=True,timeout=35)
w=json.loads(r.stdout);assert not w['processes'] and not w['tasks'] and not w['port'];assert w['blur_user'] is None and w['blur_machine'] is None
control=json.loads(Path('/tmp/viewflow-output-surface-pool/integrated-control-state.json').read_text());assert control['trials']=='completed' and not control['configerrors'];assert control['before_plugins']==control['after_plugins']
def geometry(ms):return sorted((m['name'],m['width'],m['height'],m['refreshRate'],m['x'],m['y'],m['scale'],m['transform']) for m in ms)
assert geometry(control['before_monitors'])==geometry(control['after_monitors'])
assert all(c is not None for c in control['preserved_after_unplug'])
live=json.loads(subprocess.check_output(['hyprctl','-j','monitors','all']));assert geometry(live)==geometry(control['after_monitors'])
assert subprocess.check_output(['hyprctl','configerrors'],text=True).strip()==''
p=Path('/home/wilf/data/viewflow/platform/windows-composition-preview/main.cpp');assert p.read_bytes()==(b/'source-before/main.cpp').read_bytes()
result=dict(windows=w,control_completed=True,preexisting_monitor_geometry_preserved=True,remaining_clients_preserved=len(control['preserved_after_unplug']),production_main_unchanged=True,production_main_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
for name,folder in [('main.cpp','windows-composition-preview'),('mta_video_compositor.h','windows-composition-preview'),('video_compositor.cpp','windows-video-compositor'),('video_compositor.h','windows-video-compositor')]:
 source=Path('/home/wilf/data/viewflow/platform')/folder/name
 assert source.read_bytes()==(b/'source-before'/name).read_bytes(),name
result['production_source_before_files_unchanged']=4
sender=Path('/home/wilf/data/viewflow/target/release/vf-media-peer')
result['production_sender_sha256']=hashlib.sha256(sender.read_bytes()).hexdigest()
assert result['production_sender_sha256']=='ddbc806b581037ee64abf084a8c8c77ec14c5f437e079edc44bad5b92277aae2'
(b/'method/final-state.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
