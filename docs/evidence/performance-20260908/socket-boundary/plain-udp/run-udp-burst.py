from pathlib import Path
import subprocess,base64,socket,struct,secrets,time,json,sys,os
label=sys.argv[1] if len(sys.argv)>1 else 'a1';root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip();counts=[20]*4+[150,20]*int(os.environ.get('VIEWFLOW_PROBE_PAIRS','10'));port=int(os.environ.get('VIEWFLOW_PROBE_PORT','49073'));nonce=secrets.randbits(64) or 1
serverlog=Path('/tmp/viewflow-udp-burst-'+label+'-receiver.log');script="& '"+root+"\\udp-burst-probe.exe' '"+format(nonce,'x')+"' "+str(port)+" "+str(len(counts))+"; exit $LASTEXITCODE"
command=['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()]
result=[]
with serverlog.open('w') as log:
 server=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT)
 try:
  until=time.monotonic()+10
  while time.monotonic()<until:
   if server.poll() is not None:raise RuntimeError('receiver exited before ready')
   if 'probe-ready ' in serverlog.read_text():break
   time.sleep(.05)
  else:raise RuntimeError('receiver not ready')
  sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.bind(('172.16.105.62',0));sock.settimeout(2)
  try:
   for batch,count in enumerate(counts):
    start=time.monotonic_ns()
    for seq in range(count):
     message=struct.pack('<IIIIQ',0x56465542,batch,seq,count,nonce)+bytes(1376)
     sent=sock.sendto(message,('172.16.105.70',port));assert sent==1400
    queued=time.monotonic_ns()
    ack,addr=sock.recvfrom(1500);end=time.monotonic_ns()
    assert addr==('172.16.105.70',port) and struct.unpack('<IIIIQ',ack)==(0x5646414B,batch,count,count,nonce)
    result.append(dict(batch=batch,packets=count,send_us=(queued-start)/1000,round_trip_us=(end-start)/1000))
    time.sleep(float(os.environ.get('VIEWFLOW_PROBE_PAUSE','.0167')))
  finally:sock.close()
 finally:
  # The receiver has its own absolute 30 s limit even if a packet/ack is lost.
  code=server.wait(timeout=35)
  Path('/tmp/viewflow-udp-burst-'+label+'-source.json').write_text(json.dumps(result,indent=2)+'\n')
  print('server_exit',code,'completed',len(result),'expected',len(counts))
  if code:raise RuntimeError('receiver failed')
