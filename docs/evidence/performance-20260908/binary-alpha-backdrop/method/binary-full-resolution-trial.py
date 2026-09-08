import pathlib,subprocess,json,time,sys,os
root=pathlib.Path('/tmp/viewflow-integrated-pair');label=sys.argv[1]
log=pathlib.Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log')
env=os.environ.copy();env['QT_QPA_PLATFORM']='wayland'
with log.open('w') as output:
 fixture=subprocess.Popen(['/tmp/viewflow-frame-fixture-build/viewflow_linux_frame_fixture',os.environ.get('VIEWFLOW_TRIAL_SCREEN','HEADLESS-6'),'90000'],env=env,stdout=output,stderr=subprocess.STDOUT)
 try:
  for _ in range(50):
   if fixture.poll() is not None:raise RuntimeError('fixture exited before capture')
   clients=json.loads(subprocess.check_output(['hyprctl','-j','clients']))
   matching=[c for c in clients if c['pid']==fixture.pid and c['class']=='viewflow-frame-fixture']
   if len(matching)==1:break
   time.sleep(.1)
  else:raise RuntimeError('owned fixture did not map')
  c=matching[0]
  p=json.loads(subprocess.check_output(['target/release/vf-media-peer','probe','--compositor-pid',os.environ['VIEWFLOW_TRIAL_COMPOSITOR_PID'],'--window',c['address']]))
  if c['size']!=[1920,1200] or not (3840<=p['width']<=3968 and 2400<=p['height']<=2432):raise RuntimeError('wrong fixture resolution')
  s=json.loads((root/'send.json').read_text());s['compositor_pid']=int(os.environ['VIEWFLOW_TRIAL_COMPOSITOR_PID']);s['windows'][0].update(address=c['address'],width=p['width'],height=p['height'],geometry_epoch=p['geometry_epoch']);(root/'send.json').write_text(json.dumps(s,indent=2)+'\n')
  (root/('fixture-'+label+'.json')).write_text(json.dumps(p,indent=2)+'\n');print('fixture',p,flush=True)
  subprocess.run(['python3','/tmp/viewflow-integrated-binary-backdrop-trial.py',label,'new'],check=True)
 finally:
  if fixture.poll() is None:fixture.terminate()
  fixture.wait(timeout=5)
  print('fixture_stopped',fixture.returncode,flush=True)
