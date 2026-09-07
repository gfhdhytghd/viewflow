#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH

helper=${EARLY_BOOTSTRAP_GATE_RUNTIME_HELPER_SOURCE:-/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper.py}
python3 - "$helper" <<'PY'
import base64,importlib.util,json,sys

spec=importlib.util.spec_from_file_location('runtime_helper',sys.argv[1])
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
manifest={
 'operation_id':h.OPERATION_ID,
 'identity':{'marker_generation':'1'},
 'execution':{'viewflow_unit':f'viewflow-v13-early-{h.OPERATION_ID}.service','runtime_marker_path':'/absent'},
 'installed':{
   'viewflowd':{'path':'/vf','sha256':'a'*64},
   'deskflow':{'path':'/df','sha256':'b'*64},
   'deskflow_core':{'path':'/dfc','sha256':'c'*64},
   'viewflow_unit':{'path':'/unit','sha256':'d'*64},
 },
 'windows_baseline':{
   'user_sid':h.WINDOWS_SID,'new_operation_root_path':h.WINDOWS_ROOT,
   'task_xml_sha256':'e'*64,'task_action_sha256':h.canonical_sha(h.TASK_ACTION),
   'task_principal_sha256':h.canonical_sha(h.TASK_PRINCIPAL),
   'viewflowd_sha256':'f'*64,'wrapper_sha256':'1'*64,'rollback_sha256':'2'*64,
   'executable_path':h.WINDOWS_EXE,
   'command_line_sha256':__import__('hashlib').sha256(h.WINDOWS_COMMAND.encode()).hexdigest(),
 },
 'artifacts':{'bootstrap_request':{'sha256':'3'*64}},
 'marker':{'sha256':'4'*64},
}
h.assert_manifest(manifest)

# The Linux census must reject historical Deskflow binaries even when they are
# outside the installed paths, while permitting only the exact active
# Viewflow transient whose command line contains the sidecar deskflow socket.
real_systemd_properties=h.systemd_properties
real_linux_process_census=h.linux_process_census
real_assert_deskflow_zero=h.assert_deskflow_zero
h.systemd_properties=lambda unit:{
 'LoadState':'loaded','ActiveState':'inactive','SubState':'dead','MainPID':'0',
 'InvocationID':'','ControlGroup':'','Transient':'no','KillMode':'control-group'}
h.exact_executable_pids=lambda path:[]
h.listener_count=lambda kind,needle:0
h.linux_process_census=lambda:[]
h.assert_deskflow_zero(manifest)
for bad_process in (
 {'pid':4101,'comm':'deskflow','exe':'/usr/bin/deskflow','basename':'deskflow','cmdline':['/usr/bin/deskflow']},
 {'pid':4102,'comm':'deskflow-core','exe':'/usr/bin/deskflow-core','basename':'deskflow-core','cmdline':['deskflow-core']},
):
 h.linux_process_census=lambda bad=bad_process:[bad]
 try:h.assert_deskflow_zero(manifest)
 except h.HelperError:pass
 else:raise AssertionError('historical Deskflow process accepted')
allowed=h.viewflow_argv(manifest)
h.linux_process_census=lambda:[
 {'pid':31337,'comm':'viewflowd','exe':'/vf','basename':'viewflowd','cmdline':allowed}
]
h._assert_no_unexpected_deskflow_processes(
 manifest,allowed_viewflow_pid=31337,allowed_viewflow_argv=allowed)

# A process that remains present but cannot be fully read must fail closed.
class UnreadableProcPath:
 def __init__(self,path):self.path=path
 def read_bytes(self):raise PermissionError(self.path)
old_listdir=h.os.listdir;old_path=h.Path;old_stat=h.os.stat;old_readlink=h.os.readlink
h.os.listdir=lambda path:['4242'] if path=='/proc' else old_listdir(path)
h.Path=UnreadableProcPath
h.os.stat=lambda path:object() if path=='/proc/4242' else old_stat(path)
try:real_linux_process_census()
except h.HelperError:pass
else:raise AssertionError('unreadable live process accepted')
h.os.listdir=old_listdir;h.Path=old_path;h.os.stat=old_stat;h.os.readlink=old_readlink

class NoExeProcPath:
 def __init__(self,path):self.path=path
 def read_bytes(self):return b'worker\n' if self.path.endswith('/comm') else b''
def unreadable_readlink(path):raise PermissionError(path)
def missing_exe_readlink(path):raise FileNotFoundError(path)
h.os.listdir=lambda path:['4242'] if path=='/proc' else old_listdir(path)
h.Path=NoExeProcPath;h.os.stat=lambda path:object() if path=='/proc/4242' else old_stat(path)
h.os.readlink=missing_exe_readlink
assert real_linux_process_census()==[{
 'pid':4242,'comm':b'worker','exe':b'','basename':b'','cmdline':[],'complete':True
}]
h.os.listdir=old_listdir;h.Path=old_path;h.os.stat=old_stat;h.os.readlink=old_readlink

# An unrelated process may have a permission-protected exe; its readable
# comm/cmdline remain usable and it must not abort the census.
class UnreadableExeProcPath:
 def __init__(self,path):self.path=path
 def read_bytes(self):return b'worker\n' if self.path.endswith('/comm') else b''
h.os.listdir=lambda path:['4242'] if path=='/proc' else old_listdir(path)
h.Path=UnreadableExeProcPath;h.os.stat=lambda path:object() if path=='/proc/4242' else old_stat(path)
h.os.readlink=unreadable_readlink
assert real_linux_process_census()==[{
 'pid':4242,'comm':b'worker','exe':b'','basename':b'','cmdline':[],'complete':False
}]
h.linux_process_census=lambda:real_linux_process_census()
h._assert_no_unexpected_deskflow_processes(manifest)
h.os.listdir=old_listdir;h.Path=old_path;h.os.stat=old_stat;h.os.readlink=old_readlink

class DeskflowCommPath:
 def __init__(self,path):self.path=path
 def read_bytes(self):return b'deskflow\n'
h.os.listdir=lambda path:['4242'] if path=='/proc' else old_listdir(path)
h.Path=DeskflowCommPath;h.os.stat=lambda path:object() if path=='/proc/4242' else old_stat(path)
h.os.readlink=unreadable_readlink
candidate_census=real_linux_process_census()
try:
 h.linux_process_census=lambda:candidate_census
 h._assert_no_unexpected_deskflow_processes(manifest)
except h.HelperError:pass
else:raise AssertionError('unreadable candidate executable accepted')
h.os.listdir=old_listdir;h.Path=old_path;h.os.stat=old_stat;h.os.readlink=old_readlink

# A disappearing PID is the sole permitted race exception.
h.os.listdir=lambda path:['4242'] if path=='/proc' else old_listdir(path)
h.Path=UnreadableProcPath;h.os.stat=lambda path:(_ for _ in ()).throw(FileNotFoundError(path)) if path=='/proc/4242' else old_stat(path)
assert real_linux_process_census()==[]
h.os.listdir=old_listdir;h.Path=old_path;h.os.stat=old_stat

# Unrelated processes may expose arbitrary bytes in cmdline; a candidate with
# those bytes must still be rejected by the byte-level Deskflow matcher.
h.linux_process_census=lambda:[
 {'pid':4201,'comm':b'python','exe':b'/usr/bin/python','basename':b'python',
  'cmdline':[b'python',b'\xff\xfe']}
]
h._assert_no_unexpected_deskflow_processes(manifest)
h.linux_process_census=lambda:[
 {'pid':4202,'comm':b'worker','exe':b'/tmp/worker','basename':b'worker',
  'cmdline':[b'/tmp/deskflow-core',b'\xff\xfe']}
]
try:h._assert_no_unexpected_deskflow_processes(manifest)
except h.HelperError:pass
else:raise AssertionError('non-UTF8 Deskflow candidate accepted')

# The remote census script must use collision-free PowerShell function names,
# and its output transport must be explicitly UTF-8 with progress suppressed.
old_run=h.run;captured={}
def capture_powershell(command,**kwargs):
 captured['command']=command;captured['stub']=base64.b64decode(command[-1]).decode('utf-16le');return ''
h.run=capture_powershell
h.powershell_census()
h.run=old_run
assert len(captured['command'][-1]) < h.POWERSHELL_ENCODED_COMMAND_MAX
assert 'GzipStream' in captured['stub'] and 'StreamReader' in captured['stub']
assert 'ScriptBlock]::Create' in captured['stub']
payload=__import__('re').search(r"FromBase64String\('([^']+)'\)",captured['stub']).group(1)
decoded_script=__import__('gzip').decompress(base64.b64decode(payload)).decode('utf-8')
assert decoded_script==h.powershell_census_script()
assert 'function Get-ViewflowSha256Bytes' in decoded_script
assert 'function Get-ViewflowSha256File' in decoded_script
assert '$ProgressPreference=\'SilentlyContinue\'' in decoded_script
assert '[Console]::OutputEncoding=$utf8' in decoded_script
assert 'H(' not in decoded_script and 'HF(' not in decoded_script
assert 'task_state=[string]$task.State' in decoded_script
assert 'task_state=[string]$info.State' not in decoded_script
mutated=bytearray(base64.b64decode(payload));mutated[len(mutated)//2]^=1
try:mutated_script=__import__('gzip').decompress(bytes(mutated))
except (OSError,EOFError):pass
else:assert mutated_script!=decoded_script.encode('utf-8')
old_limit=h.POWERSHELL_ENCODED_COMMAND_MAX;h.POWERSHELL_ENCODED_COMMAND_MAX=1
try:h.powershell_encoded_command(decoded_script)
except h.HelperError:pass
else:raise AssertionError('oversized encoded command accepted')
h.POWERSHELL_ENCODED_COMMAND_MAX=old_limit

# Non-UTF8 remote stderr must remain bytes on failure; successful stdout is
# the only stream that is decoded, strictly as UTF-8.
class FailedRawResult:
 returncode=1
 stdout=b'{"ignored":true}'
 stderr=b'\xd5\x00\xff'
old_subprocess_run=h.subprocess.run
h.subprocess.run=lambda *args,**kwargs:FailedRawResult()
try:h.run(['/usr/bin/ssh'])
except h.subprocess.CalledProcessError as error:assert error.stderr==b'\xd5\x00\xff'
else:raise AssertionError('raw non-UTF8 stderr was accepted')
class SuccessfulRawResult:
 returncode=0
 stdout=b'{"ok":true}'
 stderr=b'\xff'
h.subprocess.run=lambda *args,**kwargs:SuccessfulRawResult()
assert h.run(['/usr/bin/ss'])=='{"ok":true}'
h.subprocess.run=old_subprocess_run

# Query failures and empty properties must not be treated as a zero boundary.
class FailedSystemdResult:
 returncode=1
 stdout=''
 stderr='query failed'
old_subprocess_run=h.subprocess.run
h.subprocess.run=lambda *args,**kwargs:FailedSystemdResult()
try:real_systemd_properties('deskflow.service')
except h.HelperError:pass
else:raise AssertionError('systemd query failure accepted')
h.subprocess.run=old_subprocess_run

systemd_fields={
 'LoadState':'not-found','ActiveState':'inactive','SubState':'dead','MainPID':'0',
 'InvocationID':'','ControlGroup':'','Transient':'no','KillMode':'control-group'}
class NotFoundSystemdResult:
 returncode=4
 stdout='\n'.join(f'{key}={value}' for key,value in systemd_fields.items())+'\n'
 stderr='unit not found'
class Rc0NotFoundSystemdResult:
 returncode=0
 stdout=NotFoundSystemdResult.stdout
 stderr=''
h.subprocess.run=lambda *args,**kwargs:Rc0NotFoundSystemdResult()
assert real_systemd_properties('viewflow-v13-early-test.service',allow_not_found=True)['LoadState']=='not-found'
h.subprocess.run=old_subprocess_run

seen_env={}
def capture_systemd_env(*args,**kwargs):
 seen_env.update(kwargs['env']);return Rc0NotFoundSystemdResult()
h.subprocess.run=capture_systemd_env
real_systemd_properties('viewflow-v13-early-test.service',allow_not_found=True)
assert seen_env=={
 'PATH':'/usr/bin:/bin','XDG_RUNTIME_DIR':f'/run/user/{h.os.getuid()}',
 'DBUS_SESSION_BUS_ADDRESS':f'unix:path=/run/user/{h.os.getuid()}/bus'}
h.subprocess.run=old_subprocess_run

h.subprocess.run=lambda *args,**kwargs:NotFoundSystemdResult()
assert real_systemd_properties('viewflow-v13-early-test.service',allow_not_found=True)['LoadState']=='not-found'
h.subprocess.run=old_subprocess_run

class WrongSystemdResult:
 returncode=5
 stdout=NotFoundSystemdResult.stdout
 stderr='query failed'
h.subprocess.run=lambda *args,**kwargs:WrongSystemdResult()
try:real_systemd_properties('viewflow-v13-early-test.service',allow_not_found=True)
except h.HelperError:pass
else:raise AssertionError('unexpected systemd result code accepted')
h.subprocess.run=old_subprocess_run

missing_fields=dict(systemd_fields);missing_fields.pop('SubState')
class MissingSystemdResult:
 returncode=4
 stdout='\n'.join(f'{key}={value}' for key,value in missing_fields.items())+'\n'
 stderr='unit not found'
h.subprocess.run=lambda *args,**kwargs:MissingSystemdResult()
try:real_systemd_properties('viewflow-v13-early-test.service',allow_not_found=True)
except h.HelperError:pass
else:raise AssertionError('missing systemd property accepted')
h.subprocess.run=old_subprocess_run

loaded_not_found=dict(systemd_fields);loaded_not_found['LoadState']='loaded'
class WrongNotFoundSystemdResult:
 returncode=4
 stdout='\n'.join(f'{key}={value}' for key,value in loaded_not_found.items())+'\n'
 stderr='unit not found'
h.subprocess.run=lambda *args,**kwargs:WrongNotFoundSystemdResult()
try:real_systemd_properties('viewflow-v13-early-test.service',allow_not_found=True)
except h.HelperError:pass
else:raise AssertionError('rc4 loaded systemd result accepted')
h.subprocess.run=old_subprocess_run

mutated_not_found=dict(systemd_fields);mutated_not_found['ActiveState']='active'
h.assert_installed=lambda manifest:None
h.systemd_properties=lambda unit,**kwargs:mutated_not_found
h.assert_deskflow_zero=lambda *args,**kwargs:{}
h.exact_executable_pids=lambda path:[]
h.listener_count=lambda kind,needle:0
try:h.collect_linux(manifest,active=False)
except h.HelperError:pass
else:raise AssertionError('mutated not-found systemd tuple accepted')

h.systemd_properties=lambda unit:{
 'LoadState':'','ActiveState':'','SubState':'','MainPID':'',
 'InvocationID':'','ControlGroup':'','Transient':'','KillMode':''}
try:real_assert_deskflow_zero(manifest)
except h.HelperError:pass
else:raise AssertionError('empty systemd properties accepted')

census={
 'task_state':'Running','task_xml_sha256':'e'*64,
 'action_execute':h.TASK_ACTION['execute'],'action_arguments':h.TASK_ACTION['arguments'],
 'action_working_directory':h.TASK_ACTION['working_directory'],
 'principal_user_id':'wilf','principal_logon_type':'Interactive','principal_run_level':'Limited',
 'viewflowd_sha256':'f'*64,'wrapper_sha256':'1'*64,'rollback_sha256':'2'*64,
 'pid':h.WINDOWS_PID,'parent_pid':h.WINDOWS_PARENT_PID,
 'process_start_filetime_utc':h.WINDOWS_FILETIME,'session_id':1,'user_sid':h.WINDOWS_SID,
 'executable_path':h.WINDOWS_EXE,'command_line':h.WINDOWS_COMMAND,
 'new_operation_root_present':False,'new_task_present':False,
 'viewflowd_process_count':1,
 'bootstrap_worker_count':0,'installer_process_count':0,
}
h.powershell_census=lambda:json.dumps(census,separators=(',',':'))
w=h.collect_windows(manifest)
assert set(w)=={
 'task_path','task_name','task_state','task_xml_sha256','task_action_sha256','task_principal_sha256',
 'request_sha256','viewflowd_sha256','wrapper_sha256','rollback_sha256','pid','parent_pid',
 'process_start_filetime_utc','session_id','user_sid','executable_path','command_line_sha256',
 'new_operation_root_path','new_operation_root_present','new_task_path','new_task_name','new_task_present',
 'viewflowd_process_count',
 'bootstrap_worker_created','installer_process_count','mutation_permit_published',
 'initial_force_release_executed','force_release_executed','rollback_performed',
 'windows_rollback_receipt_sha256','protocol_2_1'}
assert w['pid']==22912 and w['parent_pid']==25608 and w['process_start_filetime_utc']==h.WINDOWS_FILETIME
assert not w['new_operation_root_present'] and not w['new_task_present'] and not w['bootstrap_worker_created']

bad=dict(census);bad['parent_pid']=1;h.powershell_census=lambda:json.dumps(bad)
try:h.collect_windows(manifest)
except h.HelperError:pass
else:raise AssertionError('changed parent PID accepted')

bad=dict(census);bad['viewflowd_process_count']=2;h.powershell_census=lambda:json.dumps(bad)
try:h.collect_windows(manifest)
except h.HelperError:pass
else:raise AssertionError('extra-path Windows viewflowd accepted')

# Every fresh-probe reattestation must re-read Windows and reject any drift.
stable_windows={'pid':h.WINDOWS_PID,'task_state':'Running'}
window_calls=[]
h.collect_windows=lambda m:window_calls.append('windows') or dict(stable_windows)
assert h.reattest_windows(manifest,dict(stable_windows))==stable_windows
assert window_calls==['windows']
h.collect_windows=lambda m:{'pid':h.WINDOWS_PID+1,'task_state':'Running'}
try:h.reattest_windows(manifest,dict(stable_windows))
except h.HelperError:pass
else:raise AssertionError('Windows drift during probe wait accepted')

linux={'viewflow_invocation_id':'a'*32}
s=h.snapshot('windows-v13',manifest,linux,w)
assert set(s)=={'schema_version','state','operation_id','marker_sha256','marker_generation','linux','windows'}
assert s['state']=='viewflow-early-gate-windows-v13' and s['operation_id']==h.OPERATION_ID

calls=[]
h.collect_linux=lambda m,active: ({'viewflow_invocation_id':'a'*32} if active else {'inactive':True})
start_env={}
def capture_start(command,**kwargs):
 calls.append(command);start_env.update(kwargs.get('env',{}));return ''
h.run=capture_start
assert h.start_viewflow(manifest)=={'viewflow_invocation_id':'a'*32}
assert len(calls)==1 and calls[0][0:2]==['/usr/bin/systemd-run','--user']
assert start_env==h.user_bus_env()
assert 'XDG_RUNTIME_DIR' in start_env and 'DBUS_SESSION_BUS_ADDRESS' in start_env
bad_start_env=dict(start_env);bad_start_env.pop('DBUS_SESSION_BUS_ADDRESS')
assert bad_start_env!=h.user_bus_env()
assert not any('/deskflow-scale-fix/' in arg or arg == 'deskflow.service' for arg in calls[0])

auth_old='viewflowd server authenticated peer 172.16.105.70:5555\nviewflowd server peer 172.16.105.70:5555 probe=old'
auth_new=auth_old+'\nviewflowd server peer 172.16.105.70:5555 probe=new'
old_monotonic=h.time.monotonic;old_sleep=h.time.sleep
h.time.monotonic=lambda:0;h.time.sleep=lambda seconds:None
probe_calls=iter(['unrelated journal text',auth_old])
h.run=lambda *a,**k:next(probe_calls)
h.require_fresh_probe('a'*32)

clock=[0];h.time.monotonic=lambda:clock[0];h.time.sleep=lambda seconds:clock.__setitem__(0,61)
h.run=lambda *a,**k:'unrelated journal text'
try:h.require_fresh_probe('a'*32)
except h.HelperError:pass
else:raise AssertionError('no-auth timeout accepted')

clock[0]=0;h.run=lambda *a,**k:auth_old
try:h.require_fresh_probe('a'*32)
except h.HelperError:pass
else:raise AssertionError('stale probe accepted as fresh')

clock[0]=0;h.time.sleep=lambda seconds:None
probe_calls=iter([auth_old,auth_new])
h.run=lambda *a,**k:next(probe_calls)
h.require_fresh_probe('a'*32)

h.run=lambda *a,**k:'viewflowd server authenticated peer 172.16.105.71:5555'
try:h.require_fresh_probe('a'*32)
except h.HelperError:pass
else:raise AssertionError('wrong authenticated peer accepted')
h.time.monotonic=old_monotonic;h.time.sleep=old_sleep

print('early bootstrap runtime helper hermetic fixture passed')
PY
