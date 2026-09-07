#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
export PYTHONDONTWRITEBYTECODE=1
umask 077

core_adapter=${EARLY_BOOTSTRAP_GATE_4FBA_CORE_ADAPTER:-/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort-core-4fba4c83.py}
helper_adapter=${EARLY_BOOTSTRAP_GATE_4FBA_HELPER_ADAPTER:-/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper-4fba4c83.py}
launcher=${EARLY_BOOTSTRAP_GATE_4FBA_LAUNCHER_SOURCE:-/home/wilf/data/viewflow/deploy/launch-early-bootstrap-gate-abort-4fba4c83.sh}
/usr/bin/python3 -I - "$core_adapter" "$helper_adapter" "$launcher" <<'PY'
import ast,copy,hashlib,importlib.util,json,subprocess,sys,tempfile,types
from pathlib import Path
sys.dont_write_bytecode=True

def load_adapter(path,name):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
core_adapter=load_adapter(sys.argv[1],'core_adapter');helper_adapter=load_adapter(sys.argv[2],'helper_adapter')
core=types.ModuleType('core4fba');core.__file__=sys.argv[1]+'#transformed'
exec(compile(core_adapter.operation_source(),core.__file__,'exec'),core.__dict__)
helper=types.ModuleType('helper4fba');helper.__file__=sys.argv[2]+'#transformed'
exec(compile(helper_adapter.operation_source(),helper.__file__,'exec'),helper.__dict__)

launcher=Path(sys.argv[3]);source=launcher.read_text();bootstrap=source.split("<<'PY'\n",1)[1].rsplit('\nPY\n',1)[0]
tree=ast.parse(bootstrap);values={}
for node in tree.body:
    if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name):
        try: values[node.targets[0].id]=ast.literal_eval(node.value)
        except (ValueError,TypeError): pass
derived=Path(values['BASE']).read_bytes()
for old,new,count in values['replacements']:
    assert derived.count(old.encode())==count;derived=derived.replace(old.encode(),new.encode())
embedded=derived.decode().split("<<'PY'\n")[1].split('\nPY\n',1)[0]

with tempfile.TemporaryDirectory() as directory:
    root=Path(directory);manifest_path=root/'manifest.json'
    subprocess.run(['/usr/bin/python3','-I','-c',embedded,str(manifest_path),
      '/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/viewflow-deployment-marker',
      '8d0945c582d249eb12b27f0e2eea109cc5fe20fe45358eacb3a43ff0d3880c54',
      '/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/marker-reviewed-build.json',
      '995e2a7940de17f82ef33e48ea165a8df8ba44a641c80072d711a4b0dcaefc4d'],
      check=True,stdout=subprocess.PIPE,env={'PATH':'/usr/bin:/bin'})
    manifest=json.loads(manifest_path.read_bytes())
    assert hashlib.sha256(manifest_path.read_bytes()).hexdigest()=='2933526bb2e06398248c25b10013e59f4d0bd4317dae96bb26a063036f13c47f'
    core.validate_manifest(manifest,str(manifest_path))
    assert manifest['windows_baseline']['task_xml_sha256']=='89ab8d07d19a99614361900a718e2300f6d239bf8d17b1d32101664369758b33'

    original_state=json.load(open(manifest['artifacts']['coordinator_state']['path']))
    assert original_state['contract']['identity']['windows_task_xml_sha256_override']==''
    def rejected_state(name,mutator):
        state=copy.deepcopy(original_state);mutator(state)
        raw=(json.dumps(state,sort_keys=True,separators=(',',':'))+'\n').encode();path=root/(name+'.json')
        path.write_bytes(raw);path.chmod(0o600)
        candidate=copy.deepcopy(manifest);candidate['artifacts']['coordinator_state']={'path':str(path),'sha256':hashlib.sha256(raw).hexdigest(),'mode':600}
        try: core.validate_manifest(candidate,str(manifest_path))
        except core.GateError: return
        raise AssertionError('drifted state accepted: '+name)
    rejected_state('override-nonempty',lambda s:s['contract']['identity'].update(windows_task_xml_sha256_override=manifest['windows_baseline']['task_xml_sha256']))
    rejected_state('override-missing',lambda s:s['contract']['identity'].pop('windows_task_xml_sha256_override'))
    rejected_state('remote-root',lambda s:s['contract']['remote'].update(operation_root='C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\2ca3f46635b65615a1cffc1970d73911'))
    rejected_state('wrong-phase',lambda s:s.update(phase='STOPPED'))
    rejected_state('mutation-possible',lambda s:s['recovery'].update(mutation_possible=True))

    zero=copy.deepcopy(manifest);zero['windows_baseline']['task_xml_sha256']='0'*64
    try: core.validate_manifest(zero,str(manifest_path))
    except core.GateError: pass
    else: raise AssertionError('zero task XML baseline accepted')
    wrong_marker=copy.deepcopy(manifest);wrong_marker['marker']['sha256']='0'*63+'1'
    try: core.validate_manifest(wrong_marker,str(manifest_path))
    except core.GateError: pass
    else: raise AssertionError('wrong VFDQT marker SHA accepted')

    baseline=manifest['windows_baseline']
    raw={
      'task_state':'Running','task_xml_sha256':baseline['task_xml_sha256'],
      'action_execute':helper.TASK_ACTION['execute'],'action_arguments':helper.TASK_ACTION['arguments'],
      'action_working_directory':helper.TASK_ACTION['working_directory'],
      'principal_user_id':helper.TASK_PRINCIPAL['user_id'],'principal_logon_type':helper.TASK_PRINCIPAL['logon_type'],
      'principal_run_level':helper.TASK_PRINCIPAL['run_level'],'viewflowd_sha256':baseline['viewflowd_sha256'],
      'wrapper_sha256':baseline['wrapper_sha256'],'rollback_sha256':baseline['rollback_sha256'],
      'pid':22912,'parent_pid':25608,'process_start_filetime_utc':'134326073277429320','session_id':1,
      'user_sid':helper.WINDOWS_SID,'executable_path':helper.WINDOWS_EXE,'command_line':helper.WINDOWS_COMMAND,
      'new_operation_root_present':False,'new_task_present':False,'viewflowd_process_count':1,
      'bootstrap_worker_count':0,'installer_process_count':0,
    }
    helper.powershell_census=lambda:json.dumps(raw,separators=(',',':'))
    helper.collect_windows(manifest)
    live_drift=dict(raw);live_drift['task_xml_sha256']='0'*63+'1'
    helper.powershell_census=lambda:json.dumps(live_drift,separators=(',',':'))
    try: helper.collect_windows(manifest)
    except helper.HelperError: pass
    else: raise AssertionError('live task XML drift accepted')
    wrong_baseline=copy.deepcopy(manifest);wrong_baseline['windows_baseline']['task_xml_sha256']='0'*63+'1'
    helper.powershell_census=lambda:json.dumps(raw,separators=(',',':'))
    try: helper.collect_windows(wrong_baseline)
    except helper.HelperError: pass
    else: raise AssertionError('wrong nonzero task XML baseline accepted by live attestation')
print('4fba core/helper override hermetic fixture passed')
PY
