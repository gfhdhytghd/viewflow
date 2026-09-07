#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
export PYTHONDONTWRITEBYTECODE=1
umask 077

adapter=${EARLY_BOOTSTRAP_GATE_4FBA_HELPER_ADAPTER:-/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper-4fba4c83.py}
/usr/bin/python3 -I - "$adapter" <<'PY'
import copy,hashlib,importlib.util,json,sys,types
from pathlib import Path
sys.dont_write_bytecode=True

path=Path(sys.argv[1]);spec=importlib.util.spec_from_file_location('adapter',path)
adapter=importlib.util.module_from_spec(spec);spec.loader.exec_module(adapter)
source=adapter.operation_source();helper=types.ModuleType('helper4fba')
helper.__file__=str(path)+'#transformed';exec(compile(source,helper.__file__,'exec'),helper.__dict__)
op='4fba4c832389436ba980efaa4540f6bf'
baseline={
 'viewflowd_sha256':'f4f29e16ccf678a75199b4af1c1ec3975434991bd54ca9688e961262466fcc26',
 'wrapper_sha256':'3ca9b5f498a5b80a8a54c98666e62ea84019a41fab08d2dbd8fb6f0307f47698',
 'task_xml_sha256':'89ab8d07d19a99614361900a718e2300f6d239bf8d17b1d32101664369758b33',
 'task_action_sha256':helper.canonical_sha(helper.TASK_ACTION),
 'task_principal_sha256':helper.canonical_sha(helper.TASK_PRINCIPAL),
 'rollback_sha256':'f57a3a997eb69f9d99f8d4d0bc0c5f4766f6fc8c26835e0476340356ef0930eb',
 'user_sid':helper.WINDOWS_SID,'executable_path':helper.WINDOWS_EXE,
 'command_line_sha256':hashlib.sha256(helper.WINDOWS_COMMAND.encode()).hexdigest(),
 'new_operation_root_path':helper.WINDOWS_ROOT,
}
manifest={
 'operation_id':op,'identity':{'marker_generation':'1'},
 'execution':{'viewflow_unit':'viewflow-v13-early-'+op+'.service'},
 'windows_baseline':baseline,
 'artifacts':{'bootstrap_request':{'sha256':'1587817d4f0e589e5d1c931df345b16002892ad658386bb23f98d21de5dac085'}},
}
helper.assert_manifest(manifest)

def rejected(mutator):
    value=copy.deepcopy(manifest);mutator(value)
    try: helper.assert_manifest(value)
    except helper.HelperError: return
    raise AssertionError('helper accepted a drifted operation binding')

rejected(lambda m:m.update(operation_id='0'*32))
rejected(lambda m:m['identity'].update(marker_generation='2'))
rejected(lambda m:m['execution'].update(viewflow_unit='viewflow-v13-early-2ca3f46635b65615a1cffc1970d73911.service'))
rejected(lambda m:m['windows_baseline'].update(new_operation_root_path='C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\2ca3f46635b65615a1cffc1970d73911'))
rejected(lambda m:m['windows_baseline'].update(user_sid='S-1-5-21-0'))

script=helper.powershell_census_script()
assert "$op='"+op+"'" in script
assert "'Viewflow Deployment '+$op" in script
assert "C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\'+$op" in script
assert 'Start-ScheduledTask' not in script and 'Register-ScheduledTask' not in script

raw={
 'task_state':'Running','task_xml_sha256':baseline['task_xml_sha256'],
 'action_execute':helper.TASK_ACTION['execute'],'action_arguments':helper.TASK_ACTION['arguments'],
 'action_working_directory':helper.TASK_ACTION['working_directory'],
 'principal_user_id':helper.TASK_PRINCIPAL['user_id'],'principal_logon_type':helper.TASK_PRINCIPAL['logon_type'],
 'principal_run_level':helper.TASK_PRINCIPAL['run_level'],'viewflowd_sha256':baseline['viewflowd_sha256'],
 'wrapper_sha256':baseline['wrapper_sha256'],'rollback_sha256':baseline['rollback_sha256'],
 'pid':22912,'parent_pid':25608,'process_start_filetime_utc':'134326073277429320',
 'session_id':1,'user_sid':helper.WINDOWS_SID,'executable_path':helper.WINDOWS_EXE,
 'command_line':helper.WINDOWS_COMMAND,'new_operation_root_present':False,'new_task_present':False,
 'viewflowd_process_count':1,'bootstrap_worker_count':0,'installer_process_count':0,
}
helper.powershell_census=lambda:json.dumps(raw,separators=(',',':'))
windows=helper.collect_windows(manifest)
assert windows['pid']==22912 and windows['parent_pid']==25608
assert windows['new_operation_root_path']==helper.WINDOWS_ROOT
assert windows['new_task_name']=='Viewflow Deployment '+op and windows['new_task_present'] is False
for key,value in (
 ('new_operation_root_present',True),('new_task_present',True),('bootstrap_worker_count',1),
 ('installer_process_count',1),('pid',22913),('process_start_filetime_utc','134326073277429321')):
    bad=dict(raw);bad[key]=value;helper.powershell_census=lambda bad=bad:json.dumps(bad,separators=(',',':'))
    try: helper.collect_windows(manifest)
    except helper.HelperError: pass
    else: raise AssertionError('Windows drift accepted: '+key)
print('4fba runtime helper hermetic fixture passed')
PY
