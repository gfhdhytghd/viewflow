import array,json,os,socket,subprocess,tempfile,time
from pathlib import Path
r=json.load(open('/run/user/1000/viewflow/desktop-drag/config'));env=os.environ.copy();env.update(XDG_RUNTIME_DIR='/run/user/1000',HYPRLAND_INSTANCE_SIGNATURE=r['desktop']['hyprland_socket'].split('/')[-2])
root=Path(tempfile.mkdtemp(prefix='vf-mac-reap-',dir='/dev/shm'));root.chmod(0o700)
results=[];ids=[]
def invoke(name,path):
 result=subprocess.run(['hyprctl','repl','return hl.plugin.viewflow_capture.'+name+'('+json.dumps(str(path))+')'],env=env,capture_output=True,text=True,timeout=5)
 data=json.loads(path.read_text())
 if not data.get('ok'):raise RuntimeError(result.stdout+' '+str(data))
 return data
try:
 for n in range(12):
  ident=f'mac-recovery-{os.getpid()}-{n}';ids.append(ident)
  path=root/f'{n}.sock';server=socket.socket(socket.AF_UNIX,socket.SOCK_SEQPACKET);server.bind(str(path));path.chmod(0o600);server.listen(1);server.settimeout(5)
  request=root/f'{n}.json';request.write_text(json.dumps(dict(id=ident,mode='window-gpu',fps=60,windowAddress='0x555ecdf31ba0',socketPath=str(path))));request.chmod(0o600)
  reply=invoke('window_stream_start',request)
  with server:
   connection,_=server.accept()
   with connection:
    connection.settimeout(5);data,ancillary,flags,_=connection.recvmsg(4096,socket.CMSG_SPACE(16));fds=[]
    for level,kind,payload in ancillary:
     if level==socket.SOL_SOCKET and kind==socket.SCM_RIGHTS:
      values=array.array('i');values.frombytes(payload[:len(payload)//values.itemsize*values.itemsize]);fds.extend(values)
    for fd in fds:os.close(fd)
    if len(fds)!=2 or not data:raise RuntimeError('missing GPU frame/fence')
    results.append(dict(iteration=n+1,accepted=reply['ok'],packet_bytes=len(data),received_fds=len(fds)))
  # No release receipt: simulate a receiver crash, without reading GPU pixels.
  time.sleep(.12)
finally:
 for n,ident in enumerate(ids):
  p=root/f'{n}-stop.json';p.write_text(json.dumps(dict(streamId=ident)));p.chmod(0o600);invoke('window_stream_stop',p)
Path('docs/evidence/macos-blur-performance-20260910/reconnect-probe.json').write_text(json.dumps(results,indent=2)+'\n')
print('12 receiver disconnect/reconnect cycles passed; each captured a real GPU packet; all streams explicitly stopped; no input')
