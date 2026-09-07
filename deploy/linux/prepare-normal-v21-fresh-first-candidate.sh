#!/usr/bin/env bash
# Create a schema-v1 candidate for a bridge-created operation with no prior
# candidate.  Replacement history is deliberately neither accepted nor made.
set -Eeuo pipefail
export LC_ALL=C
umask 077
exec python3 - "$@" <<'PY'
import ctypes,hashlib,json,os,re,secrets,shutil,stat,sys
from pathlib import Path
S=Path(os.environ.get('VIEWFLOW_PIPELINE_STATE','/home/wilf/.local/state/viewflow')); C=S/'candidates'; D=S/'deployments'
SEED=Path(os.environ.get('VIEWFLOW_FRESH_FIRST_SEED',str(C/'v21-normal-seed-v3-20260904T123027Z-oZ1vdq'))); SEEDSHA=os.environ.get('VIEWFLOW_FRESH_FIRST_SEED_SHA','07bbb719e07ae03a9591a8dc0bf2603bf8a9538ea42774c31bd050bca2004be0')
FILES={'windows-viewflowd.exe':('87631e877811377f018d65dc5ca2b1d6b68e2b268d7d15b8d0646aac3d9f5b04',0o700),'windows-native-provenance.json':('fc4cb5cff71ad859f113cd2ad21cfff90217401772cba08f21c0394735bac17d',0o600),'windows-source.manifest.sha256':('7ecccb607a166c847aa1293905f8fd14909803734751b6ca71549470fc6f95e2',0o600),'windows-source.tar.gz':('da3014217499fc7deb5eac1fa07fb85e9cbfcecb0bff9fd14df54530d3367131',0o600),'windows-source.tar.gz.sha256':('aea8ec8fe6232e0883b97e58cd027e735b1e2a39b2c3761b5a3fcadbff7139ee',0o600)}
TOP='schema_version kind operation_id coordinator_instance_id protocol_version sidecar_protocol_version marker_generation recovery_marker_generation source_display_id target_device_id fresh_boundary coordinator linux_rust linux_deskflow windows'.split()
def die(x): raise SystemExit('error: fresh-first candidate: '+x)
def reg(p,m=None):
 try: s=os.lstat(p)
 except OSError as e: die('missing '+str(p))
 if not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_uid!=os.getuid() or s.st_nlink!=1 or (m is not None and stat.S_IMODE(s.st_mode)!=m): die('unsafe '+str(p))
 return s
def od(p):
 try: s=os.lstat(p)
 except OSError: die('missing directory '+str(p))
 if not stat.S_ISDIR(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_uid!=os.getuid() or stat.S_IMODE(s.st_mode)!=0o700: die('unsafe directory '+str(p))
def sha(p):
 fd=os.open(p,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW); a=os.fstat(fd)
 if not stat.S_ISREG(a.st_mode) or a.st_uid!=os.getuid() or a.st_nlink!=1: die('unsafe '+str(p))
 h=hashlib.sha256()
 try:
  while True:
   x=os.read(fd,131072)
   if not x: break
   h.update(x)
  z=os.fstat(fd)
 finally: os.close(fd)
 b=reg(p)
 if not ((a.st_dev,a.st_ino,a.st_size,a.st_mtime_ns)==(z.st_dev,z.st_ino,z.st_size,z.st_mtime_ns)==(b.st_dev,b.st_ino,b.st_size,b.st_mtime_ns)): die('changed '+str(p))
 return h.hexdigest()
def pairs(a):
 d={}
 for k,v in a:
  if k in d: raise ValueError('duplicate key')
  d[k]=v
 return d
def load(p):
 reg(p,0o600)
 try:
  fd=os.open(p,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW); data=b''
  try:
   while True:
    q=os.read(fd,131072)
    if not q: break
    data+=q
  finally: os.close(fd)
  t=data.decode('utf-8','strict'); x,e=json.JSONDecoder(object_pairs_hook=pairs,parse_float=lambda _:(_ for _ in ()).throw(ValueError()),parse_constant=lambda _:(_ for _ in ()).throw(ValueError())).raw_decode(t)
 except Exception as z: die('JSON '+str(p))
 if t[e:].strip() or type(x) is not dict: die('noncanonical JSON '+str(p))
 return x
def eq(x,k,v,l):
 if x.get(k)!=v: die(l+' '+k+' differs')
def rename_new(a,b):
 f=ctypes.CDLL(None,use_errno=True).renameat2; f.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
 if f(-100,os.fsencode(a),-100,os.fsencode(b),1): die('candidate publication failed')
a=sys.argv[1:]; names={'--operation-id':'op','--coordinator-uuid':'co','--fresh-root':'root','--handoff':'handoff','--frozen':'frozen','--publish':'publish','--bridge-final-receipt':'bridge','--bridge-final-receipt-sha256':'bsha'}; v={}; check=False; resume=False; i=0
while i<len(a):
 if a[i]=='--check-only': check=True; i+=1; continue
 if a[i]=='--resume': resume=True; i+=1; continue
 if a[i] not in names or i+1==len(a): die('unknown/incomplete option')
 v[names[a[i]]]=a[i+1]; i+=2
if set(v)!=set(names.values()): die('all arguments required')
op,co=v['op'],v['co'];
if not re.fullmatch('[0-9a-f]{32}',op) or not re.fullmatch('[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',co) or not re.fullmatch('[0-9a-f]{64}',v['bsha']): die('canonical identity required')
root=Path(v['root']); cand=C/('v21-operation-'+op)
commit=root/'first-candidate-commit.json'
if root!=D/op or root.resolve()!=root: die('fresh root identity')
for p in (S,C,D,root): od(p)
for k in ('handoff','frozen','publish','bridge'):
 if Path(v[k]).parent!=root: die(k+' must be direct root leaf')
p,h,f,b=load(Path(v['publish'])),load(Path(v['handoff'])),load(Path(v['frozen'])),load(Path(v['bridge']))
if sha(Path(v['bridge']))!=v['bsha']: die('bridge SHA differs')
for x,l in ((p,'publish'),(h,'handoff')): eq(x,'operation_id',op,l);eq(x,'coordinator_instance_id',co,l)
eq(p,'state','deployment-quarantine-published','publish');eq(h,'state','viewflow-v13-marker-handoff-prepared','handoff');eq(f,'state','viewflow-v13-bootstrap-frozen','frozen');eq(f,'operation_id',op,'frozen')
if h.get('deployment_publish_receipt_path')!=v['publish'] or h.get('deployment_publish_receipt_sha256')!=sha(Path(v['publish'])): die('handoff publish closure')
if list(b)!=['schema_version','state','old_operation_id','new_operation_id','new_coordinator_instance_id','marker_generation','inactive_source','persistent_v13','fresh_boundary'] or b.get('schema_version')!=1 or b.get('state')!='viewflow-v4-inactive-terminal-to-fresh-v21' or b.get('new_operation_id')!=op or b.get('new_coordinator_instance_id')!=co or b.get('marker_generation')!='1': die('bridge final identity')
if not isinstance(b.get('old_operation_id'),str) or not re.fullmatch('[0-9a-f]{32}',b['old_operation_id']) or b['old_operation_id']==op: die('bridge old operation identity')
inactive=b.get('inactive_source'); persistent=b.get('persistent_v13')
if not isinstance(inactive,dict) or list(inactive)!=['source_validation_sha256','terminal_sha256','authorization_sha256','abort_receipt_sha256','abort_query_receipt_sha256','vfdqa_sha256','linux_initially_inactive','windows_old_peer_unchanged'] or not all(isinstance(inactive.get(k),str) and re.fullmatch('[0-9a-f]{64}',inactive[k]) for k in list(inactive)[:6]) or inactive.get('linux_initially_inactive') is not True or inactive.get('windows_old_peer_unchanged') is not True: die('bridge inactive-source closure')
if not isinstance(persistent,dict) or list(persistent)!=['persistent_started_sha256','authenticated_probe_record_sha256','stopped_by_collector'] or not all(isinstance(persistent.get(k),str) and re.fullmatch('[0-9a-f]{64}',persistent[k]) for k in list(persistent)[:2]) or persistent.get('stopped_by_collector') is not True: die('bridge persistent-v13 closure')
want={'deployment_publish_sha256':sha(Path(v['publish'])),'marker_handoff_sha256':sha(Path(v['handoff'])),'linux_frozen_sha256':sha(Path(v['frozen'])),'deployment_marker_sha256':p.get('marker_sha256'),'protocol_version':'2.1'}
if b.get('fresh_boundary')!=want: die('bridge fresh boundary')
if sha(SEED/'candidate-manifest.json')!=SEEDSHA: die('seed SHA differs')
seed=load(SEED/'candidate-manifest.json')
od(SEED)
if set(os.listdir(SEED))!={'candidate-manifest.json',*FILES}: die('seed exact six leaves')
if list(seed)!=TOP or seed.get('schema_version')!=1 or seed.get('kind')!='viewflow-v21-cross-host-candidate-set' or seed.get('protocol_version')!='2.1' or seed.get('sidecar_protocol_version')!=3: die('seed contract')
mb={'root':str(root),'deployment_publish_receipt_sha256':want['deployment_publish_sha256'],'marker_handoff_sha256':want['marker_handoff_sha256'],'linux_frozen_sha256':want['linux_frozen_sha256'],'deployment_marker':p.get('marker_path'),'deployment_marker_sha256':p.get('marker_sha256')}
def candidate_tree():
 od(cand)
 expected=set(FILES)|{'candidate-manifest.json'}
 entries=set(os.listdir(cand))
 if entries!=expected: die('candidate exact six leaves')
 rows=[]
 for n,(x,m) in sorted(FILES.items()):
  q=cand/n; reg(q,m)
  if sha(q)!=x: die('candidate artifact SHA '+n)
  rows.append(n+'\0'+format(m,'04o')+'\0'+str(os.stat(q).st_size)+'\0'+x+'\n')
 q=cand/'candidate-manifest.json'; reg(q,0o600); m=load(q); msha=sha(q)
 if list(m)!=TOP or m.get('schema_version')!=1 or m.get('kind')!='viewflow-v21-cross-host-candidate-set' or m.get('operation_id')!=op or m.get('coordinator_instance_id')!=co or m.get('fresh_boundary')!=mb or 'candidate_replacement' in m: die('candidate schema1 binding')
 if m.get('windows',{}).get('viewflowd')!=str(cand/'windows-viewflowd.exe') or m.get('windows',{}).get('native_provenance')!=str(cand/'windows-native-provenance.json'): die('candidate Windows paths')
 rows.append('candidate-manifest.json\0'+'0600\0'+str(os.stat(q).st_size)+'\0'+msha+'\n')
 return msha,hashlib.sha256(''.join(sorted(rows)).encode('ascii')).hexdigest()
def receipt_for(msha,tree):
 return {'schema_version':1,'state':'viewflow-normal-v21-first-candidate-committed','operation_id':op,'coordinator_instance_id':co,'operation_root':str(root),'candidate_root':str(cand),'candidate_manifest_path':str(cand/'candidate-manifest.json'),'candidate_manifest_sha256':msha,'candidate_tree_sha256':tree,'bridge_final_path':v['bridge'],'bridge_final_sha256':v['bsha'],'fresh_boundary':want}
def write_all(fd,data,label):
 n=0
 while n<len(data):
  q=os.write(fd,data[n:])
  if q<=0: die('short '+label)
  n+=q
def commit_once(receipt):
 if os.path.lexists(commit):
  if list(load(commit))!=list(receipt) or load(commit)!=receipt: die('existing first-candidate receipt differs')
  return False
 data=(json.dumps(receipt,separators=(',',':'))+'\n').encode();fd=os.open(commit,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 try: write_all(fd,data,'first-candidate receipt write');os.fsync(fd)
 finally: os.close(fd)
 dfd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
 try: os.fsync(dfd)
 finally: os.close(dfd)
 return True
if os.path.lexists(cand):
 if not resume: die('candidate exists; use --resume only for strict first-candidate recovery')
 msha,tree=candidate_tree()
 if check: print('fresh-first candidate resume checks passed'); raise SystemExit(0)
 created=commit_once(receipt_for(msha,tree));print(('recovered' if created else 'replayed')+' fresh-first candidate: '+str(cand));print('candidate manifest sha256: '+msha);raise SystemExit(0)
if os.path.lexists(commit): die('first-candidate receipt exists without candidate')
if resume: die('--resume requires an existing candidate')
if check: print('fresh-first candidate prerequisites passed'); raise SystemExit(0)
stage=C/('.v21-first-'+op+'.staging-'+str(os.getpid())+'-'+secrets.token_hex(8))
try:
 os.mkdir(stage,0o700)
 for n,(x,m) in FILES.items():
  src=SEED/n; sfd=os.open(src,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW); before=os.fstat(sfd)
  if not stat.S_ISREG(before.st_mode) or before.st_uid!=os.getuid() or before.st_nlink!=1 or stat.S_IMODE(before.st_mode)!=m: die('unsafe seed artifact '+n)
  fd=os.open(stage/n,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,m)
  try:
   h=hashlib.sha256()
   while True:
    z=os.read(sfd,131072)
    if not z: break
    h.update(z);write_all(fd,z,'candidate artifact write')
   os.fsync(fd);after=os.fstat(sfd)
  finally: os.close(fd);os.close(sfd)
  named=reg(src,m)
  if not ((before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)==(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns)==(named.st_dev,named.st_ino,named.st_size,named.st_mtime_ns)) or h.hexdigest()!=x: die('seed artifact SHA '+n)
  if sha(stage/n)!=x: die('copy SHA '+n)
 out=json.loads(json.dumps(seed));out['operation_id']=op;out['coordinator_instance_id']=co;out['fresh_boundary']=mb;out['windows']['viewflowd']=str(cand/'windows-viewflowd.exe');out['windows']['native_provenance']=str(cand/'windows-native-provenance.json')
 data=(json.dumps(out,indent=2,ensure_ascii=True)+'\n').encode();fd=os.open(stage/'candidate-manifest.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 try:
  n=0
  while n<len(data):
   q=os.write(fd,data[n:])
   if q<=0: die('short manifest write')
   n+=q
  os.fsync(fd)
 finally: os.close(fd)
 rename_new(stage,cand)
 dfd=os.open(C,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);os.fsync(dfd);os.close(dfd)
 # This is the only crash-sensitive boundary.  A later --resume revalidates
 # the complete candidate tree before it can create this receipt.
 if os.environ.get('VIEWFLOW_FRESH_FIRST_CRASH_AFTER_RENAME')=='1': raise SystemExit('injected crash after candidate publication')
 msha,tree=candidate_tree();commit_once(receipt_for(msha,tree))
 print('prepared fresh-first normal v2.1 candidate: '+str(cand));print('candidate manifest sha256: '+msha);print('first candidate commit: '+str(commit))
except BaseException:
 if stage.exists(): shutil.rmtree(stage,ignore_errors=True)
 raise
PY
