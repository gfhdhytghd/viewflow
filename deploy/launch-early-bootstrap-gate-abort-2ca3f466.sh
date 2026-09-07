#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

readonly OP=2ca3f46635b65615a1cffc1970d73911
readonly ROOT=/home/wilf/.local/state/viewflow/deployments/$OP
readonly CORE=/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort.py
readonly CORE_SHA=feb107342827abc813f5262829a77ddecb6ca1cc19e30cde2710dff540ce87f6
readonly HELPER=/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper.py
readonly HELPER_SHA=bd562f25214cf337bd09c5b82c4ed866fdc8ac79ffb9da22ac8f5b380d659ac7
readonly MANIFEST=$ROOT/early-bootstrap-gate-abort-manifest.v11.json
readonly FINAL_MARKER_CANDIDATE=/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/viewflow-deployment-marker
readonly FINAL_MARKER_CANDIDATE_SHA=8d0945c582d249eb12b27f0e2eea109cc5fe20fe45358eacb3a43ff0d3880c54
readonly FINAL_REVIEWED_BUILD_MANIFEST=/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/marker-reviewed-build.json
readonly FINAL_REVIEWED_BUILD_MANIFEST_SHA=995e2a7940de17f82ef33e48ea165a8df8ba44a641c80072d711a4b0dcaefc4d

candidate=''
candidate_sha=''
reviewed_build_manifest=''
reviewed_build_manifest_sha=''
mode=check-only
die() { printf '2ca3 early gate launcher: %s\n' "$*" >&2; exit 1; }
usage() {
    printf 'usage: %s --marker-candidate ABSOLUTE_ELF --marker-candidate-sha256 SHA256 --reviewed-build-manifest ABSOLUTE_JSON --reviewed-build-manifest-sha256 SHA256 [--check-only|--execute]\n' "$0" >&2
    exit 64
}
while (($#)); do
    case $1 in
        --marker-candidate) (($# >= 2)) || usage; candidate=$2; shift 2 ;;
        --marker-candidate-sha256) (($# >= 2)) || usage; candidate_sha=$2; shift 2 ;;
        --reviewed-build-manifest) (($# >= 2)) || usage; reviewed_build_manifest=$2; shift 2 ;;
        --reviewed-build-manifest-sha256) (($# >= 2)) || usage; reviewed_build_manifest_sha=$2; shift 2 ;;
        --check-only) [[ $mode == check-only ]] || usage; shift ;;
        --execute) [[ $mode == check-only ]] || usage; mode=execute; shift ;;
        *) usage ;;
    esac
done
[[ $candidate == /* && $candidate_sha =~ ^[0-9a-f]{64}$ && $reviewed_build_manifest == /* && $reviewed_build_manifest_sha =~ ^[0-9a-f]{64}$ ]] || usage
[[ $candidate == "$FINAL_MARKER_CANDIDATE" && $candidate_sha == "$FINAL_MARKER_CANDIDATE_SHA" && $reviewed_build_manifest == "$FINAL_REVIEWED_BUILD_MANIFEST" && $reviewed_build_manifest_sha == "$FINAL_REVIEWED_BUILD_MANIFEST_SHA" ]] || die 'reviewed marker candidate/provenance differs from fixed binding'

require_exact() {
    local label=$1 path=$2 sha=$3 expected_mode=$4
    [[ -f $path && ! -L $path ]] || die "$label is not a regular non-symlink"
    [[ $(stat -c %U -- "$path") == wilf && $(stat -c %h -- "$path") == 1 ]] || die "$label owner/link differs"
    [[ $(stat -c %a -- "$path") == "$expected_mode" ]] || die "$label mode differs"
    [[ $(sha256sum -- "$path" | cut -d ' ' -f 1) == "$sha" ]] || die "$label SHA-256 differs"
}

require_exact helper "$HELPER" "$HELPER_SHA" 755
require_exact native-marker-candidate "$candidate" "$candidate_sha" 755
require_exact reviewed-marker-build-manifest "$reviewed_build_manifest" "$reviewed_build_manifest_sha" 600
[[ $(od -An -tx1 -N4 -- "$candidate" | tr -d ' \n') == 7f454c46 ]] || die 'marker candidate is not native ELF'
[[ -d $ROOT && ! -L $ROOT && $(stat -c %U -- "$ROOT") == wilf ]] || die 'operation root differs'
(( (8#$(stat -c %a -- "$ROOT") & 8#077) == 0 )) || die 'operation root is not owner-only'

/usr/bin/python3 -I - "$MANIFEST" "$candidate" "$candidate_sha" "$reviewed_build_manifest" "$reviewed_build_manifest_sha" <<'PY'
import ctypes,hashlib,json,os,stat,sys
from pathlib import Path
RENAME_NOREPLACE=1

manifest_path,candidate,candidate_sha,reviewed_build_manifest,reviewed_build_manifest_sha=sys.argv[1:]
op='2ca3f46635b65615a1cffc1970d73911'
root=Path('/home/wilf/.local/state/viewflow/deployments')/op
def spec(path,sha,mode):return {'path':path,'sha256':sha,'mode':mode}
artifacts={
 'coordinator_state':spec(str(root/'coordinator-state.json'),'6eeae66cd921777b7f00c037c5fea8d78230d031533f94f6023c8bd2ec99cd3f',600),
 'marker_handoff':spec(str(root/'marker-handoff.json'),'24f8ba7e065c8a060b013eab8a5509c77ebeaf573619329f4a1d1ba8f83e64a6',600),
 'linux_frozen':spec(str(root/'linux-frozen.json'),'acd3065ec439790e8f1344420a79df2667fb57abdba2f5be1b77293d723821f1',600),
 'deployment_publish':spec(str(root/'deployment-publish.json'),'eebbefd9e50842f4b96aee61299e35c2a07d697b211e70b0c2c16a6b27004fe3',600),
 'bootstrap_request':spec(str(root/'windows-bootstrap-request.json'),'12cf89c18d9cdcdfb2f5a9222edb5e9331c3ed4d3826e25120ce7bfe20b8283e',600),
 'windows_stop_evidence':spec(str(root/'coordinator-state.json.windows-stop-evidence.json'),'130a6c1cc8aef2bc0e349b4fdc233238ea193da4fabbf9370e988e8a3233be87',600),
}
installed={
 'viewflowd':spec('/home/wilf/.local/lib/viewflow/viewflowd','d142fbbc65e311fa17b3307c252689afbb3963dda3e265cedc3bca7887daf96d',755),
 'deskflow':spec('/home/wilf/.local/lib/deskflow-scale-fix/deskflow','033065b0495a2b996a6731ecf6e47c2af476e1c120ab5d62dafb8b8aa3394c3f',755),
 'deskflow_core':spec('/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core','e2ebbfe39a1b7f5f3e30953340c000e5b249e8d957ceda5fb0e9c4efad0ffd52',755),
 'viewflow_unit':spec('/home/wilf/.config/systemd/user/viewflow-peer.service','2a9595405c449fc36c45c6cf82c4906321ca15e18c2f4ee92f42313a845487ec',644),
}
outputs={name:str(root/('early-gate-'+name.replace('_','-')+'.json')) for name in (
 'windows_live','linux_started','windows_started','authenticated_peer','authorization','abort_receipt',
 'pre_abort_reattest','post_abort_reattest','terminal')}
marker_path='/home/wilf/.local/state/viewflow/deployment-quarantine.v1'
runtime_marker='/home/wilf/.local/state/viewflow/deskflow-quarantine.v2'
abort_claim='/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim'
release_claim='/home/wilf/.local/state/viewflow/deployment-quarantine.v1.release-claim'
manifest={
 'schema_version':1,'state':'viewflow-early-bootstrap-gate-abort-manifest','operation_id':op,
 'identity':{'coordinator_instance_id':'ad0e2ad1-608f-4aee-8701-900fe6c7fd6a',
             'source_display_id':'00000000-0000-0000-0000-000000000101',
             'target_device_id':'00000000-0000-0000-0000-000000000002','marker_generation':'1'},
 'artifacts':artifacts,'installed':installed,
 'marker':spec(marker_path,'6dcad80272677fc561485d74026f70fe3591ca6e4a8c3586ff20c1ee4121855f',600),
 'windows_baseline':{
   'viewflowd_sha256':'f4f29e16ccf678a75199b4af1c1ec3975434991bd54ca9688e961262466fcc26',
   'wrapper_sha256':'3ca9b5f498a5b80a8a54c98666e62ea84019a41fab08d2dbd8fb6f0307f47698',
   'task_xml_sha256':'89ab8d07d19a99614361900a718e2300f6d239bf8d17b1d32101664369758b33',
   'task_action_sha256':'4f0ac6b10c22358093c339f967552ea230ddc462f67f01c17b504c99133dd3ef',
   'task_principal_sha256':'8170560069f2c818437ebe20158904e27019f09c27a2bb2f3d87330ef205073b',
   'rollback_sha256':'f57a3a997eb69f9d99f8d4d0bc0c5f4766f6fc8c26835e0476340356ef0930eb',
   'user_sid':'S-1-5-21-1940417919-1835306932-1635351729-1001',
   'executable_path':r'C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe',
   'command_line_sha256':'caac96175cfb23b6670e42e0915e343333f56ccd6543d60495fc531bff736d5e',
   'new_operation_root_path':'C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\'+op,
 },
 'runtime_helper':spec('/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper.py',
                       'bd562f25214cf337bd09c5b82c4ed866fdc8ac79ffb9da22ac8f5b380d659ac7',755),
 'execution':{'marker_candidate':{'path':candidate,'sha256':candidate_sha,'mode':755,
                                  'reviewed_build_manifest':spec(reviewed_build_manifest,reviewed_build_manifest_sha,600)},
              'viewflow_unit':'viewflow-v13-early-'+op+'.service','marker_path':marker_path,
              'runtime_marker_path':runtime_marker,'abort_claim_path':abort_claim,'release_claim_path':release_claim},
 'outputs':outputs,'required_absent':[runtime_marker,abort_claim,release_claim],
}
raw=(json.dumps(manifest,sort_keys=True,separators=(',',':'))+'\n').encode()
target=Path(manifest_path)
if not target.is_absolute() or target.name in ('','.','..'):
 raise SystemExit('manifest path/parent is unsafe')
parent_fd=os.open(target.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
def read_exact(fd,size):
 data=b''
 while len(data)<size:
  chunk=os.read(fd,min(1<<20,size-len(data)))
  if not chunk: raise SystemExit('manifest short read')
  data+=chunk
 return data
def parent_identity(value):
 return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,value.st_nlink)
def reattest_parent(expected):
 current_fd=os.fstat(parent_fd);current_path=os.stat(target.parent,follow_symlinks=False)
 if parent_identity(current_fd)!=parent_identity(expected) or parent_identity(current_path)!=parent_identity(expected):
  raise SystemExit('manifest parent identity changed')
def validate_existing(fd,expected):
 before=os.fstat(fd)
 existing=read_exact(fd,before.st_size)
 if os.read(fd,1): raise SystemExit('existing manifest grew while read')
 after=os.fstat(fd);current=os.stat(target.name,dir_fd=parent_fd,follow_symlinks=False)
 identity=lambda value:(value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,value.st_nlink,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
 if (identity(before)!=identity(after) or identity(after)!=identity(current)
     or not stat.S_ISREG(before.st_mode) or existing!=expected
     or before.st_uid!=os.geteuid() or before.st_nlink!=1
     or stat.S_IMODE(before.st_mode)!=0o600
     or any(name in ('system.posix_acl_access','system.posix_acl_default') for name in os.listxattr(fd))):
  raise SystemExit('existing manifest differs')
 os.fsync(fd)
 reattest_parent(parent_stat)
temporary=None
try:
 pst=os.fstat(parent_fd)
 if (pst.st_uid!=os.geteuid() or stat.S_IMODE(pst.st_mode)&0o077
     or any(name in ('system.posix_acl_access','system.posix_acl_default') for name in os.listxattr(parent_fd))):
  raise SystemExit('manifest parent is not owner-only')
 parent_stat=pst
 try:
  fd=os.open(target.name,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=parent_fd)
 except FileNotFoundError:fd=None
 if fd is not None:
  try:validate_existing(fd,raw)
  finally:os.close(fd)
 else:
  # A random component makes a stale temporary left by a killed publisher
  # harmless, including after PID reuse.  O_EXCL and mode 0600 make creation
  # owner-only and no-replace before the atomic rename boundary.
  temporary='.'+target.name+'.tmp.'+str(os.getpid())+'.'+os.urandom(16).hex()
  fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC,0o600,dir_fd=parent_fd)
  try:
   temporary_stat=os.fstat(fd)
   if (not stat.S_ISREG(temporary_stat.st_mode) or temporary_stat.st_uid!=os.geteuid()
       or temporary_stat.st_nlink!=1 or stat.S_IMODE(temporary_stat.st_mode)!=0o600):
    raise SystemExit('temporary manifest metadata differs')
   view=memoryview(raw)
   while view:
    count=os.write(fd,view)
    if count<=0:raise SystemExit('manifest short write')
    view=view[count:]
   os.fsync(fd)
  finally:os.close(fd)
  libc=ctypes.CDLL(None,use_errno=True)
  try:renameat2=libc.renameat2
  except AttributeError:raise SystemExit('renameat2 is unavailable')
  renameat2.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
  renameat2.restype=ctypes.c_int
  result=renameat2(parent_fd,os.fsencode(temporary),parent_fd,os.fsencode(target.name),RENAME_NOREPLACE)
  if result!=0:
   error=ctypes.get_errno()
   if error==17:
    try:
     fd=os.open(target.name,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=parent_fd)
    except FileNotFoundError:raise SystemExit('manifest appeared concurrently then disappeared')
    try:validate_existing(fd,raw)
    finally:os.close(fd)
   else:raise SystemExit(f'manifest no-replace rename failed: errno {error}')
  else:
   os.fsync(parent_fd)
   reattest_parent(parent_stat)
   fd=os.open(target.name,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=parent_fd)
   try:
    readback_stat=os.fstat(fd);readback=read_exact(fd,readback_stat.st_size)
    if (os.read(fd,1) or (readback_stat.st_dev,readback_stat.st_ino)!=(temporary_stat.st_dev,temporary_stat.st_ino)
        or readback!=raw):
     raise SystemExit('manifest readback differs')
   finally:os.close(fd)
finally:
 if temporary is not None:
  try:os.unlink(temporary,dir_fd=parent_fd)
  except FileNotFoundError:pass
 os.close(parent_fd)
print(hashlib.sha256(raw).hexdigest())
PY

manifest_sha=$(sha256sum -- "$MANIFEST" | cut -d ' ' -f 1)
if [[ $mode == execute ]]; then
    core_mode=--execute
else
    core_mode=--check-only
fi
exec /usr/bin/python3 -I - "$CORE" "$CORE_SHA" "$core_mode" "$MANIFEST" "$manifest_sha" <<'PY'
import ctypes,fcntl,hashlib,os,stat,sys

core_path,expected_sha,core_mode,manifest_path,manifest_sha=sys.argv[1:]
if core_mode not in ('--execute','--check-only'):
 raise SystemExit('invalid core mode')
core_fd=os.open(core_path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 before=os.fstat(core_fd)
 if (not stat.S_ISREG(before.st_mode) or before.st_uid!=os.geteuid()
     or before.st_nlink!=1 or stat.S_IMODE(before.st_mode)!=0o755
     or any(name in ('system.posix_acl_access','system.posix_acl_default') for name in os.listxattr(core_fd))):
  raise SystemExit('core metadata differs')
 data=b''
 while len(data)<before.st_size:
  chunk=os.read(core_fd,min(1<<20,before.st_size-len(data)))
  if not chunk: raise SystemExit('core short read')
  data+=chunk
 if os.read(core_fd,1): raise SystemExit('core grew while read')
 after=os.fstat(core_fd)
 current=os.stat(core_path,follow_symlinks=False)
 identity=lambda value:(value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,value.st_nlink,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
 if (identity(before)!=identity(after) or identity(after)!=identity(current)
     or hashlib.sha256(data).hexdigest()!=expected_sha):
  raise SystemExit('core identity or SHA-256 differs')
 seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
 memfd=os.memfd_create('viewflow-early-bootstrap-gate-abort-core',os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)
 try:
  view=memoryview(data)
  while view:
   count=os.write(memfd,view)
   if count<=0: raise SystemExit('sealed core short write')
   view=view[count:]
  os.lseek(memfd,0,os.SEEK_SET)
  fcntl.fcntl(memfd,fcntl.F_ADD_SEALS,seals)
  if fcntl.fcntl(memfd,fcntl.F_GET_SEALS)!=seals:
   raise SystemExit('sealed core flags differ')
  flags=fcntl.fcntl(memfd,fcntl.F_GETFD)
  fcntl.fcntl(memfd,fcntl.F_SETFD,flags & ~fcntl.FD_CLOEXEC)
  os.execve('/usr/bin/python3',['/usr/bin/python3','-I',f'/proc/self/fd/{memfd}',
                               '--manifest',manifest_path,'--manifest-sha256',manifest_sha,core_mode],
            {'PATH':'/usr/bin:/bin'})
 finally:
  os.close(memfd)
finally:
 os.close(core_fd)
PY
