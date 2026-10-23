from pathlib import Path
import subprocess,base64,json,time,os,signal,hashlib,sys
b=Path(__file__).resolve().parent.parent;stage=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-transport-20260909';label=sys.argv[1];assert label.replace('-','').isalnum();remote=stage+'\\runs\\'+label;task='ViewflowPerf-Reverse6KTransport-'+label;nested=json.loads(Path(os.environ['VIEWFLOW_REVERSE_NESTED_STATE']).read_text());out=b/'runs'/label;out.mkdir(parents=True);created=False;client=None;observer=None
state={'nested_state':nested}
def ps(s,timeout=35):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 if r.returncode:raise RuntimeError((r.returncode,(r.stdout+r.stderr).decode(errors='replace')))
 return r.stdout.decode(errors='replace').strip()
def info(*args):return json.loads(subprocess.check_output(['hyprctl','-j',*args],text=True))
def winstate():return json.loads(ps("[pscustomobject]@{port=@(Get-NetUDPEndpoint -LocalPort 49073 -ErrorAction SilentlyContinue).Count;processes=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -like '*reverse-transport-20260909*' -or $_.ExecutablePath -like '*reverse-mft-inspection-20260909*' -or $_.ExecutablePath -like '*reverse-mft-speed0-20260909*' -or $_.ExecutablePath -like '*reverse-process-priority-20260909*'}|Select-Object ProcessId,ParentProcessId,ExecutablePath);installed=(Get-FileHash 'C:\\Users\\wilf\\Viewflow\\desktop-test\\viewflow_windows_reverse.exe').Hash;main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString()}|ConvertTo-Json -Depth 5"))
def save(): (out/'state.json').write_text(json.dumps(state,indent=2)+'\n')
state['before']=winstate();assert not state['before']['port'] and not state['before']['processes'];save()
ps("if(Test-Path '"+remote+"'){throw 'run directory exists'};New-Item -ItemType Directory '"+remote+"\\build' -Force|Out-Null;Copy-Item '"+stage+"\\build\\Release' '"+remote+"\\build\\Release' -Recurse")
assert sys.argv[2] in ['0','1']
ps("Copy-Item '"+stage+"\\build\\Release\\viewflow_reverse_perf_waitable_fixture.exe' '"+remote+"\\build\\Release\\viewflow_reverse_perf_fixture.exe' -Force")
work=json.loads(Path('/tmp/viewflow-full-glass-work.json').read_text());local=Path(work['local']);oldwin=json.loads((local/'receive.json').read_text());oldlinux=json.loads((local/'send.json').read_text())
keys=['certificate','private_key','certificate_authority'];wc={k:oldwin[k] for k in keys};wc.update(bind='0.0.0.0:49073',remote=None,role='source',backend={'native':r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-process-priority-20260909\build\Release\viewflow_windows_reverse.exe','args':['-6144','-780','0','2676']},diagnostic_duration_ms=35000)
lc={k:oldlinux[k] for k in keys};lc.update(bind='0.0.0.0:0',remote='172.16.105.70:49073',server_name='glass-receiver.test',role='presenter',backend={'native':'/tmp/viewflow-reverse-baseline-linux/viewflow_linux_reverse','args':['3072','390','2']},diagnostic_duration_ms=32000)
state['native_hash_before']=ps("(Get-FileHash '"+wc['backend']['native']+"').Hash");state['quality_vs_speed']=0;state['direct_single_surface']=1;state['alpha_summary']=1;state['capture_changes']=1;state['normal_priority']=int(sys.argv[2]);state['fixture_queue']='waitable-max-latency-1'
(out/'source.json').write_text(json.dumps(wc,indent=2)+'\n');(out/'presenter.json').write_text(json.dumps(lc,indent=2)+'\n')
subprocess.run(['scp','-q',str(out/'source.json'),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/source.json'],check=True,timeout=30)
peer=Path('/home/wilf/data/viewflow/target/release/vf-window-perf-peer');native=Path(lc['backend']['native']);ob=Path('/tmp/viewflow-reverse-desktop-observer/viewflow_reverse_desktop_observer');state['linux_binaries']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [peer,native,ob]};state['windows_binaries']=json.loads(ps("Get-ChildItem '"+remote+"\\build\\Release\\*.exe'|ForEach-Object{[pscustomobject]@{path=$_.FullName;hash=(Get-FileHash $_.FullName).Hash}}|ConvertTo-Json"));save()
subprocess.run([str(peer),'validate','--config',str(out/'presenter.json')],check=True)
try:
 ps("if(Get-ScheduledTask '"+task+"' -ErrorAction SilentlyContinue){throw 'task exists'};if(Test-Path '"+remote+"\\status.log'){throw 'trial already exists'};$principal=(Get-ScheduledTask 'ViewflowMain-Active').Principal;$action=New-ScheduledTaskAction -Execute '"+remote+"\\build\\Release\\viewflow_reverse_perf_priority_runner.exe' -Argument '\""+remote+"\" "+sys.argv[2]+"' -WorkingDirectory '"+remote+"';Register-ScheduledTask -TaskName '"+task+"' -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null")
 created=True;ps("Start-ScheduledTask '"+task+"'");print('Windows transport scheduled',flush=True)
 for _ in range(20):
  if int(ps("@(Get-NetUDPEndpoint -LocalPort 49073 -ErrorAction SilentlyContinue).Count"))==1:break
  time.sleep(.15)
 else:raise RuntimeError('paired listener did not start')
 log=(out/'linux.log').open('w');client=subprocess.Popen([str(peer),'--config',str(out/'presenter.json')],env=os.environ.copy(),stdout=log,stderr=subprocess.STDOUT)
 for _ in range(100):
  if client.poll() is not None:raise RuntimeError('Linux peer exited before proxy')
  windows=[x for x in info('clients') if x['class'].startswith('ViewflowReverse-')]
  if windows and windows[0]['size']==[3072,1728] and windows[0]['at']==[0,0]:break
  time.sleep(.1)
 else:raise RuntimeError('6K proxy not mapped at expected geometry')
 assert len(windows)==1 and info('activewindow').get('pid')!=windows[0]['pid'];state['proxy']=windows[0];state['inner_monitors']=info('monitors','all');save();print('6K paired proxy ready',flush=True)

 state['native_scheduling']=json.loads(ps("$native=Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq '"+wc['backend']['native']+"'};if(@($native).Count -ne 1){throw 'expected one native source'};$process=Get-Process -Id $native.ProcessId;[pscustomobject]@{pid=$native.ProcessId;path=$native.ExecutablePath;process_class=$process.PriorityClass.ToString();base_priority=$process.BasePriority;threads=@($process.Threads|Group-Object BasePriority|Select-Object Name,Count);task_priority=(Get-ScheduledTask '"+task+"').Settings.Priority}|ConvertTo-Json -Depth 4"));save()
 ol=(out/'desktop.log').open('w');oe=(out/'desktop.stderr.log').open('w');observer=subprocess.Popen([str(ob),nested['screen'],'20000'],stdout=ol,stderr=oe)
 observer.wait(timeout=25);state['observer_exit']=observer.returncode;save();ol.close();oe.close();assert observer.returncode==0
 client.wait(timeout=25);state['client_exit']=client.returncode;log.close();assert client.returncode==0
 for _ in range(15):
  ws=json.loads(ps("$t=Get-ScheduledTask '"+task+"';[pscustomobject]@{state=$t.State.ToString();result=(Get-ScheduledTaskInfo $t).LastTaskResult}|ConvertTo-Json"))
  if ws['state']!='Running':break
  time.sleep(.5)
 state['task']=ws;save();assert ws['state']=='Ready' and ws['result']==0,ws
finally:
 for proc in [observer,client]:
  if proc is not None and proc.poll() is None:
   proc.terminate()
   try:proc.wait(timeout=5)
   except subprocess.TimeoutExpired:proc.kill();proc.wait()
 if created:ps("if((Get-ScheduledTask '"+task+"').State -eq 'Running'){Stop-ScheduledTask '"+task+"'};Unregister-ScheduledTask '"+task+"' -Confirm:$false")
 state['native_hash_after']=ps("(Get-FileHash '"+wc['backend']['native']+"').Hash");assert state['native_hash_after']==state['native_hash_before'];state['after']=winstate();state['remaining_proxies']=[x for x in info('clients') if x['class'].startswith('ViewflowReverse-')];save()
 if created:
  for name in ['status.log','source.log','fixture.log','peer.stdout.log']:
   subprocess.run(['scp','-q','wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+name,str(out/name)],check=True,timeout=30)
assert not state['after']['processes'] and not state['after']['port'] and not state['remaining_proxies'];assert state['after']['installed']==state['before']['installed'];print('transport cleanup passed',flush=True)
