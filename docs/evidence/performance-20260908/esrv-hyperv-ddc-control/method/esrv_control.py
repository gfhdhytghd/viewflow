from pathlib import Path
import subprocess,base64,json
class Control:
 def __init__(self):
  self.path=Path(__file__).resolve().parent/'priority-control.json'
  self.task='ViewflowPerf-RestoreEsrvHvDdc'
  self.registered=False
  initial=self.ps(r'''$s=Get-CimInstance Win32_Service -Filter "Name='ESRV_SVC_QUEENCREEK'";$p=Get-Process -Id $s.ProcessId;$threads=@($p.Threads|Where-Object {$_.PriorityLevel -eq 'TimeCritical'});if($s.State -ne 'Running' -or $p.Path -ne 'C:\Program Files\Intel\SUR\QUEENCREEK\x64\esrv_svc.exe' -or $p.PriorityClass -ne 'High' -or $threads.Count -ne 2){throw 'original Intel telemetry state changed'};[pscustomobject]@{id=$p.Id;start_ticks=$p.StartTime.ToUniversalTime().Ticks.ToString();path=$p.Path;priority=$p.PriorityClass.ToString();service_state=$s.State;service_start=$s.StartMode;threads=@($threads|ForEach-Object{[pscustomobject]@{id=$_.Id;start_ticks=$_.StartTime.ToUniversalTime().Ticks.ToString();priority=$_.PriorityLevel.ToString();base=$_.BasePriority;cpu_ms=$_.TotalProcessorTime.TotalMilliseconds}})}|ConvertTo-Json -Depth 5''')
  self.initial=json.loads(initial);self.data={'initial':self.initial,'phases':[]};self.save()
  i=self.initial
  self.identity=f"$s=Get-CimInstance Win32_Service -Filter \"Name='ESRV_SVC_QUEENCREEK'\";$p=Get-Process -Id {i['id']};if($s.ProcessId -ne $p.Id -or $p.StartTime.ToUniversalTime().Ticks.ToString() -ne '{i['start_ticks']}'){{throw 'process identity changed'}};"
  self.identity+="$selected=@();"
  for t in i['threads']:
   self.identity+=f"$t=@($p.Threads|Where-Object Id -eq {t['id']});if($t.Count -ne 1 -or $t[0].StartTime.ToUniversalTime().Ticks.ToString() -ne '{t['start_ticks']}'){{throw 'thread identity changed'}};$selected+=$t[0];"
  self.readback=r'''$p.Refresh();[pscustomobject]@{id=$p.Id;start_ticks=$p.StartTime.ToUniversalTime().Ticks.ToString();priority=$p.PriorityClass.ToString();service_state=$s.State;service_start=$s.StartMode;threads=@($p.Threads|Where-Object {$_.Id -in $selected.Id -or $_.PriorityLevel -eq 'TimeCritical'}|ForEach-Object{[pscustomobject]@{id=$_.Id;start_ticks=$_.StartTime.ToUniversalTime().Ticks.ToString();priority=$_.PriorityLevel.ToString();base=$_.BasePriority;cpu_ms=$_.TotalProcessorTime.TotalMilliseconds}})}|ConvertTo-Json -Depth 5'''
  self.restore_code=f"$p=Get-Process -Id {i['id']} -ErrorAction SilentlyContinue;if($p -and $p.StartTime.ToUniversalTime().Ticks.ToString() -eq '{i['start_ticks']}'){{"
  for t in i['threads']:
   self.restore_code+=f"$t=@($p.Threads|Where-Object Id -eq {t['id']});if($t.Count -eq 1 -and $t[0].StartTime.ToUniversalTime().Ticks.ToString() -eq '{t['start_ticks']}' -and $t[0].PriorityLevel -eq 'Normal'){{$t[0].PriorityLevel='TimeCritical'}};"
  self.restore_code+="if($p.PriorityClass -eq 'Normal'){$p.PriorityClass='High'}}"
  (self.path.parent/'restore-command.ps1').write_text(self.restore_code+'\n')
  self.ps("if(Get-ScheduledTask -TaskName '"+self.task+"' -ErrorAction SilentlyContinue){throw 'restoration task already exists'};$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -EncodedCommand "+base64.b64encode(self.restore_code.encode('utf-16le')).decode()+"';$t=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10);Register-ScheduledTask -TaskName '"+self.task+"' -Action $a -Trigger $t -User 'SYSTEM' -RunLevel Highest|Out-Null")
  self.registered=True;self.data['restore_task_registered']=True;self.save()
 def ps(self,s):
  s="$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s
  r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=40)
  if r.returncode:raise RuntimeError((r.stdout+r.stderr).decode(errors='replace'))
  return r.stdout.decode(errors='replace').strip()
 def save(self):self.path.write_text(json.dumps(self.data,indent=2)+'\n')
 def validate(self,v,mode):
  assert v['id']==self.initial['id'] and v['start_ticks']==self.initial['start_ticks']
  assert v['service_state']==self.initial['service_state'] and v['service_start']==self.initial['service_start']
  assert v['priority']==('Normal' if mode=='normal' else 'High')
  expected={t['id']:t for t in self.initial['threads']}
  assert {t['id'] for t in v['threads']}==set(expected)
  for t in v['threads']:
   assert t['start_ticks']==expected[t['id']]['start_ticks'] and t['priority']==('Normal' if mode=='normal' else 'TimeCritical') and t['base']==(8 if mode=='normal' else 15)
 def set(self,mode,label):
  assert mode in ['original','normal']
  p,t=('Normal','Normal') if mode=='normal' else ('High','TimeCritical')
  v=json.loads(self.ps(self.identity+f"$p.PriorityClass='{p}';foreach($thread in $selected){{$thread.PriorityLevel='{t}'}};"+self.readback));self.validate(v,mode)
  self.data['phases'].append({'label':label,'mode':mode,'before':v});self.save()
 def check(self,mode,label):
  v=json.loads(self.ps(self.identity+self.readback));self.validate(v,mode);assert self.data['phases'][-1]['label']==label
  self.data['phases'][-1]['after']=v;self.save()
 def restore(self):
  if not self.registered:return
  self.ps(self.restore_code)
  v=json.loads(self.ps(self.identity+self.readback));self.validate(v,'original');self.data['restored']=v;self.save()
  self.ps("Unregister-ScheduledTask -TaskName '"+self.task+"' -Confirm:$false;if(Get-ScheduledTask -TaskName '"+self.task+"' -ErrorAction SilentlyContinue){throw 'restore task remains'}")
  self.data['restore_task_removed']=True;self.registered=False;self.save()
