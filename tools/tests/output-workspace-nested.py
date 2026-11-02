"""Nested-only workspace integration test. No live IPC or input injection.

--wayland-physical-fixture requires a separately built test plugin whose sole
change recognizes AQ_BACKEND_WAYLAND in recall's physical() predicate. Never
install that fixture. Production mode verifies the no-DRM error instead.
"""
import argparse
import os,sys,subprocess,tempfile,time,json
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--hyprland',required=True)
parser.add_argument('--input-plugin',required=True)
parser.add_argument('--headless-format-preload',required=True)
parser.add_argument('--artifacts',required=True)
parser.add_argument('--wayland-physical-fixture',action='store_true')
args=parser.parse_args()
from pathlib import Path
artifacts=Path(args.artifacts);artifacts.mkdir(parents=True,exist_ok=True)
r=Path(tempfile.mkdtemp(prefix='vfw-')); env=dict(os.environ)
parent=env['WAYLAND_DISPLAY']; parent=parent if parent.startswith('/') else str(Path(env['XDG_RUNTIME_DIR'])/parent)
env.update(XDG_RUNTIME_DIR=str(r),WAYLAND_DISPLAY=parent,XDG_CONFIG_HOME=str(r/'config'),XDG_CACHE_HOME=str(r/'cache'),HYPRLAND_NO_SD_VARS='1',HYPRLAND_NO_SD_NOTIFY='1',HYPRLAND_NO_DBUS='1',LD_PRELOAD=str(Path(args.headless_format_preload).resolve()))
env.pop('HYPRLAND_INSTANCE_SIGNATURE',None)
c=r/'test.lua';c.write_text("hl.monitor({output='',mode='1280x800@60',position='auto',scale=1})\nhl.config({animations={enabled=false},misc={disable_hyprland_logo=true,disable_splash_rendering=true}})\n")
p=subprocess.Popen([str(Path(args.hyprland).resolve()),'-c',str(c)],env=env,stdout=open(artifacts/'compositor.log','w'),stderr=subprocess.STDOUT,start_new_session=True)
try:
    for i in range(200):
        locks=list((r/'hypr').glob('*/hyprland.lock'))
        if locks and (locks[0].parent/'.socket.sock').exists():break
        if p.poll() is not None:raise RuntimeError('nested exit '+str(p.returncode))
        time.sleep(.05)
    lock=locks[0];assert lock.read_text().splitlines()[0]==str(p.pid)
    env.update(HYPRLAND_INSTANCE_SIGNATURE=lock.parent.name,WAYLAND_DISPLAY=lock.read_text().splitlines()[1]);env.pop('LD_PRELOAD')
    def ctl(*a):
        assert p.poll() is None and lock.read_text().splitlines()[0]==str(p.pid)
        out=subprocess.check_output(['hyprctl',*a],env=env,text=True,stderr=subprocess.STDOUT,timeout=10).strip();print(a,out,flush=True);return out
    ctl('-j','monitors');ctl('output','create','headless');time.sleep(.6);ctl('-j','monitors')
    ctl('plugin','load',str(Path(args.input_plugin).resolve()));time.sleep(.5)
    ctl('eval','return hl.plugin.viewflow.recall_shortcut()');ctl('repl','return hl.plugin.viewflow.recall_shortcut()')
    import importlib.util
    spec=importlib.util.spec_from_file_location('autostart',Path(__file__).resolve().parents[1]/'desktop-autostart-linux.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    mons=json.loads(ctl('-j','monitors')); remote=next(m['name'] for m in mons if m['name'].startswith('HEADLESS')); local=next(m['name'] for m in mons if not m['name'].startswith('HEADLESS'))
    ctl('eval',f'hl.monitor({{output="{remote}",mode="1280x800@60",position="1280x0",scale=1}})');time.sleep(.5)
    ctl('eval',f'hl.get_monitor("{remote}"):set_workspace(7)')
    clients=[]
    try:
        for n in range(2):
            clients.append(subprocess.Popen(['weston-terminal'],env=env,stdout=open(artifacts/('client'+str(n)+'.log'),'w'),stderr=subprocess.STDOUT))
        time.sleep(1)
        ws=json.loads(ctl('-j','clients'));assert len(ws)==2,ws
        for w in ws:ctl('eval','hl.dispatch(hl.dsp.window.move({window="address:'+w['address']+'",workspace="7",follow=false}))')
        before=json.loads(ctl('-j','activewindow'))
        expression=mod.special_workspace_expression(remote,'viewflow-test','viewflow-test-underlay');ctl('eval',expression);time.sleep(.4)
        mons=json.loads(ctl('-j','monitors'));m=next(m for m in mons if m['name']==remote)
        assert m['activeWorkspace']['name']=='viewflow-test-underlay',m
        assert mod.special_workspace_active(m,'viewflow-test'),m
        assert json.loads(ctl('-j','activewindow')).get('address')==before.get('address')
        ws=json.loads(ctl('-j','clients'));assert all(w['workspace']['name'].removeprefix('special:')=='viewflow-test' for w in ws),ws
        assert all(not w['floating'] for w in ws),ws
        print('PASS numbered migration of two tiled windows',flush=True)
        ctl('eval',f'hl.get_monitor("{remote}"):set_special_workspace(nil)');ctl('eval',expression)
        assert mod.special_workspace_active(next(m for m in json.loads(ctl('-j','monitors')) if m['name']==remote),'viewflow-test')
        print('PASS special deactivation recovery',flush=True)
        # Deliberate underlay move emulates a drag/routing fallback; reconciliation drains it.
        addr=ws[0]['address']
        ctl('eval','hl.dispatch(hl.dsp.window.move({window="address:'+addr+'",workspace="name:viewflow-test-underlay",follow=false}))')
        assert next(w for w in json.loads(ctl('-j','clients')) if w['address']==addr)['workspace']['name']=='viewflow-test-underlay'
        ctl('eval',expression)
        assert next(w for w in json.loads(ctl('-j','clients')) if w['address']==addr)['workspace']['name'].removeprefix('special:')=='viewflow-test'
        print('PASS underlay drain',flush=True)
        ctl('reload');time.sleep(.5);ctl('eval',expression)
        assert mod.special_workspace_active(next(m for m in json.loads(ctl('-j','monitors')) if m['name']==remote),'viewflow-test')
        print('PASS reload reconciliation',flush=True)
        # Recall from a tiled underlay window, without moving/focusing live input.
        ctl('eval','hl.dispatch(hl.dsp.window.move({window="address:'+addr+'",workspace="name:viewflow-test-underlay",follow=false}))')
        if args.wayland_physical_fixture:
            target=next(m for m in json.loads(ctl('-j','monitors')) if m['name']==local)['activeWorkspace']['name']
            focus_before=json.loads(ctl('-j','activewindow')).get('address')
            result=json.loads(ctl('repl','return hl.plugin.viewflow.recall_windows(false)'))
            assert result['ok'] and result['moved']==2,result
            recalled=json.loads(ctl('-j','clients'))
            assert all(w['workspace']['name']==target and w['floating'] for w in recalled),recalled
            assert json.loads(ctl('-j','activewindow')).get('address')==focus_before
            print('PASS tiled underlay/special recall with Wayland physical fixture; focus retained',flush=True)
        else:
            result=json.loads(ctl('repl','return hl.plugin.viewflow.recall_windows(true)'))
            assert not result['ok'] and result['error']=='No physical display',result
            print('PASS production plugin rejects missing DRM destination',flush=True)
        # Verify normal numbered selection on the local monitor stays local.
        ctl('eval',f'hl.get_monitor("{local}"):set_workspace(7)')
        assert next(m for m in json.loads(ctl('-j','monitors')) if m['name']==local)['activeWorkspace']['name']=='7'
        print('PASS numbered workspace reusable on local monitor',flush=True)

    finally:
        for child in clients:child.terminate();child.wait(timeout=10)

finally:
    p.terminate();p.wait(timeout=15)
