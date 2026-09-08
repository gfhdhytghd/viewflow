import array,json,os,pathlib,select,socket,struct,subprocess,time,ctypes,statistics
state=json.loads(pathlib.Path(os.environ['VIEWFLOW_COMMIT_STATE']).read_text());root=pathlib.Path(state['root']);report={'frames':[]};fixtures=[];logs=[];streams={};sockets=[];held={}
def ctl(*args):return subprocess.check_output(['/usr/bin/hyprctl',*args],text=True,timeout=10)
def request(op,data):
 path=root/('rpc-'+str(time.monotonic_ns())+'.json');fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w') as f:json.dump(data,f)
 result=ctl('repl','return hl.plugin.viewflow_capture_phase_test.window_stream_'+op+'('+json.dumps(str(path))+')')
 reply=json.loads(path.read_text());assert reply.get('ok'),(result,reply)
 return reply

def start(name,window,mode='commit'):
 s=socket.socket(socket.AF_UNIX,socket.SOCK_SEQPACKET);p=root/(name+'-'+str(time.monotonic_ns())+'.sock');s.bind(str(p));p.chmod(0o600);s.listen(1);s.settimeout(8);sockets.append(s)
 request('start_commit' if mode=='commit' else 'start',dict(id=name,socketPath=str(p),windowAddress=window['address'],fps=60,mode='window-gpu'))
 c,_=s.accept();c.settimeout(8);sockets.append(c);streams[name]=(c,window);return c

def recv(name):
 c,window=streams[name];data,anc,flags,_=c.recvmsg(320,socket.CMSG_SPACE(8));fds=array.array('i')
 for level,typ,raw in anc:
  if level==socket.SOL_SOCKET and typ==socket.SCM_RIGHTS:fds.frombytes(raw)
 try:
  assert not flags&(socket.MSG_TRUNC|socket.MSG_CTRUNC)
  assert len(data)==320 and data[:8]==b'HCGF\x00\x01\x00\xe8' and len(fds)==2
  assert data[232:240]==b'HCGI\x00\x01\x00\x58'
  address,surface,pid,x,y,w,h,sw,sh=struct.unpack_from('>QQQ6d',data,240)
  assert address==int(window['address'],16) and pid==window['pid'] and surface
  assert [w,h]==window['size'] and [sw,sh]==window['size'],(window,[w,h,sw,sh])
  assert select.select([fds[1]],[],[],5)[0],'fence timed out'
  seq,cap,epoch=struct.unpack_from('>QQQ',data,8)
  report['frames'].append(dict(stream=name,sequence=seq,capture_ns=cap,epoch=epoch,receive_ns=time.monotonic_ns(),width=int.from_bytes(data[64:68],'big'),height=int.from_bytes(data[68:72],'big')))
  held[name]=data
  return data,fds
 except:
  for fd in fds:os.close(fd)
  raise

def release(name):
 data=held.pop(name);streams[name][0].send(b'HCGR\x00\x01\x00\x20'+data[8:16]+data[24:32]+bytes(8))
def frame(name):
 data,fds=recv(name)
 for fd in fds:os.close(fd)
 release(name);return data

def stop(name):
 if name in held:release(name)
 request('stop',{'streamId':name});streams.pop(name)
try:
 env=dict(os.environ,QT_QPA_PLATFORM='wayland')
 for i in range(2):
  log=(root/f'fixture-{i}.log').open('w');logs.append(log)
  p=subprocess.Popen(['/tmp/viewflow-full-glass-9hp_jra7/fixture-build/viewflow_linux_frame_fixture',state['screen'],'90000'],env=env,stdout=log,stderr=subprocess.STDOUT);fixtures.append(p)
  for _ in range(60):
   clients=json.loads(ctl('-j','clients'));matches=[x for x in clients if x['pid']==p.pid]
   if len(matches)==1 and matches[0]['size']==[1920,1200]:break
   if p.poll() is not None:raise RuntimeError('fixture died')
   time.sleep(.1)
  else:raise RuntimeError('fixture did not map at expected geometry')
  assert matches[0]['monitor']==state['inner_monitor']['id'],matches[0]
  report.setdefault('windows',[]).append(matches[0])
 report['monitors']=json.loads(ctl('-j','monitors','all'))
 for i,w in enumerate(report['windows']):start('cohort-'+str(i),w)
 # Hold the first exported frame from A while B continues receiving real GPU frames.
 data,fds=recv('cohort-0')
 try:
  for _ in range(12):frame('cohort-1')
  assert not select.select([streams['cohort-0'][0]],[],[],.05)[0],'held frame was reused before release'
  report['held_a_b_progress']=True
 finally:
  for fd in fds:os.close(fd)
 release('cohort-0')
 for _ in range(60):frame('cohort-0');frame('cohort-1')
 stop('cohort-0')
 for _ in range(12):frame('cohort-1')
 report['survives_peer_stop']=True
 stop('cohort-1')
 # Empty-cohort removal and same-id recreation exercise timer and listener cleanup.
 start('cohort-0',report['windows'][0])
 for _ in range(12):frame('cohort-0')
 stop('cohort-0');report['restart_after_empty']=True
 start('grid-0',report['windows'][0],mode='grid')
 for _ in range(12):frame('grid-0')
 stop('grid-0');report['legacy_grid']=True
 report['passed']=True
 print('COHORT_SMOKE_PASS frames='+str(len(report['frames'])),flush=True)
finally:
 for name in list(streams):
  try:stop(name)
  except Exception as e:report.setdefault('cleanup_errors',[]).append(str(e))
 for s in sockets:s.close()
 for p in fixtures:
  if p.poll() is None:p.terminate()
  p.wait(timeout=5)
 report['fixture_exits']=[p.returncode for p in fixtures]
 for log in logs:log.close()
 (root/'smoke.json').write_text(json.dumps(report,indent=2)+'\n')
