from pathlib import Path
import subprocess,base64,socket,struct,secrets,time,json,sys
label,mode=sys.argv[1:];assert mode in ['blocking','nonblocking'] and all(c.isalnum() or c=='-' for c in label)
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip();directory=root+'\\interactive-udp-'+label;task='ViewflowPerf-InteractiveUDPProbe';nonce=secrets.randbits(64) or 1;counts=[20]*4+[150,20]*12
out=Path('/tmp/viewflow-interactive-udp-'+label);out.mkdir(exist_ok=True)
def ps(s):
 prefix="$ProgressPreference='SilentlyContinue'; $OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $ErrorActionPreference='Stop'; "
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode((prefix+s).encode('utf-16le')).decode()],capture_output=True,timeout=30);r.check_returncode();return r.stdout.decode(errors='replace')
created=False;result=[]
try:
 args='"'+root+'\\udp-parity-probe.exe" '+format(nonce,'x')+' 49101 '+str(len(counts))+' "'+directory+'" '+mode
 s="if(Get-ScheduledTask -TaskName '"+task+"' -ErrorAction SilentlyContinue){throw 'probe task already exists'}; New-Item -ItemType Directory -Force '"+directory+"' | Out-Null; $a=New-ScheduledTaskAction -Execute '"+root+"\\udp-interactive-runner.exe' -Argument '"+args+"' -WorkingDirectory '"+root+"'; $p=New-ScheduledTaskPrincipal -UserId 'wilf' -LogonType Interactive -RunLevel Highest; $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1); Register-ScheduledTask -TaskName '"+task+"' -Action $a -Principal $p -Settings $settings | Out-Null; Start-ScheduledTask -TaskName '"+task+"'"
 ps(s);created=True
 until=time.monotonic()+12
 while time.monotonic()<until:
  log=ps("if(Test-Path '"+directory+"\\probe-output.log'){Get-Content '"+directory+"\\probe-output.log'}")
  if 'probe-ready ' in log:break
  time.sleep(.1)
 else:raise RuntimeError('interactive probe not ready')
 state=ps("Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith('"+root+"',[StringComparison]::OrdinalIgnoreCase)} | Select-Object Name,ProcessId,SessionId,ExecutablePath | ConvertTo-Json")
 (out/'process-sessions.json').write_text(state);states=json.loads(state);assert len({p['SessionId'] for p in states})==1 and any(p['Name']=='vf-media-peer.exe' for p in states),'probe and active receiver must share interactive session'
 sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.bind(('172.16.105.62',0));sock.setsockopt(socket.IPPROTO_IP,socket.IP_TOS,2);sock.setsockopt(socket.IPPROTO_IP,10,2);sock.settimeout(2)
 try:
  for batch,count in enumerate(counts):
   payload=secrets.token_bytes(1419);start=time.monotonic_ns()
   for sequence in range(count):
    packet=struct.pack('<IIIIQ',0x56465542,batch,sequence,count,nonce)+payload;assert sock.sendto(packet,('172.16.105.70',49101))==1443
   queued=time.monotonic_ns();ack,peer=sock.recvfrom(1500);end=time.monotonic_ns();assert peer==('172.16.105.70',49101) and struct.unpack('<IIIIQ',ack)==(0x5646414B,batch,count,count,nonce)
   result.append(dict(batch=batch,packets=count,source_begin_ns=start,source_end_ns=end,send_us=(queued-start)/1000,round_trip_us=(end-start)/1000));time.sleep(.05)
 finally:sock.close()
finally:
 (out/'source.json').write_text(json.dumps({'mode':mode,'bytes':1443,'ecn':2,'df':True,'payload':'nonce header and random tail','batches':result},indent=2)+'\n')
 if created:
  until=time.monotonic()+40
  while time.monotonic()<until:
   status=ps("Get-ScheduledTask -TaskName '"+task+"' | Select-Object -ExpandProperty State")
   if status.strip()!='Running':break
   time.sleep(.5)
  else:raise RuntimeError('probe task remains active')
  for n in ['probe-output.log','probe-status.log']:
   subprocess.run(['scp','-q','-o','BatchMode=yes','wilf@172.16.105.70:'+directory.replace('\\','/')+'/'+n,str(out/n)],check=True)
  ps("Unregister-ScheduledTask -TaskName '"+task+"' -Confirm:$false")
  status=(out/'probe-status.log').read_text();assert 'probe_exit=0 watchdog=0' in status,status
print('interactive_probe',label,mode,'batches',len(result),'max_rtt_ms',max(r['round_trip_us']/1000 for r in result),flush=True)
