import pathlib,tempfile,os,subprocess,shutil
with tempfile.TemporaryDirectory() as d:
 p=pathlib.Path(d); b=p/'bin'; b.mkdir(); script=p/'viewflow-target.sh'
 shutil.copyfile(pathlib.Path.home()/'.config/HyprV/quickshell/scripts/viewflow-target.sh',script)
 def exe(path,text): path.write_text(text);path.chmod(0o755)
 exe(b/'systemctl', '''#!/usr/bin/python3
import os,pathlib,sys
p=pathlib.Path(os.environ['TEST_STATE']);a=[s for s in sys.argv[1:] if s not in ('--user','--quiet')];cmd,target=a[:2]
current=p.read_text() if p.exists() else ''
if cmd=='is-active': sys.exit(0 if current==target else 3)
if cmd=='start': p.write_text(target)
if cmd=='stop' and current==target: p.write_text('')
''')
 exe(b/'python3', '''#!/usr/bin/python3
import os,sys
sys.stdin.read()
sys.exit(1 if len(sys.argv)>2 and sys.argv[2]==os.environ.get('FAIL_TARGET') else 0)
''')
 exe(p/'hdmi-switch-ir.py','#!/bin/sh\nexit "${FAIL_IR:-0}"\n')
 env={**os.environ,'PATH':str(b)+':'+os.environ['PATH'],'XDG_CONFIG_HOME':str(p/'config'),'XDG_STATE_HOME':str(p/'state'),'XDG_RUNTIME_DIR':str(p/'run'),'TEST_STATE':str(p/'active')}
 (p/'active').write_text('viewflow-desktop.service')
 def call(target,extra={}):return subprocess.run(['bash',str(script),'set',target],env={**env,**extra},capture_output=True,text=True)
 r=call('macos');assert r.returncode==0,r.stderr;assert (p/'active').read_text()=='viewflow-macos-input.service'
 r=call('windows');assert r.returncode==0,r.stderr;assert (p/'active').read_text()=='viewflow-desktop.service'
 r=call('macos',{'FAIL_TARGET':'macos'});assert r.returncode!=0;assert (p/'active').read_text()=='viewflow-desktop.service';assert (p/'state/hyprv/viewflow-target').read_text().strip()=='windows'
 r=call('macos',{'FAIL_IR':'1'});assert r.returncode!=0;assert (p/'state/hyprv/viewflow-target').read_text().strip()=='macos';assert 'HDMI' in r.stderr
 r=call('bogus');assert r.returncode!=0;assert (p/'active').read_text()=='viewflow-macos-input.service'
 print('PASS: both targets, failed-start rollback, HDMI failure state, invalid target')
