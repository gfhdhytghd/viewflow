#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

# The reviewed 2ca3 launcher is a frozen generator/sealed-core bootstrap.  Keep
# it byte-for-byte unchanged and derive only the operation-specific literals
# below into a sealed memfd.  The derived launcher never exists as a mutable
# path and its manifest is still published create-once/no-replace by the
# reviewed bootstrap.
exec /usr/bin/python3 -I - "$@" <<'PY'
import fcntl,hashlib,os,stat,sys

BASE='/home/wilf/data/viewflow/deploy/launch-early-bootstrap-gate-abort-2ca3f466.sh'
BASE_SHA='e9b877a85d507033f6ffc3c9f91b3e8a0e12603b8eae118660aff7c314bb5f3f'
replacements=(
 ('2ca3f46635b65615a1cffc1970d73911','4fba4c832389436ba980efaa4540f6bf',2),
 ('2ca3 early gate launcher','4fba early gate launcher',1),
 ('early-bootstrap-gate-abort-manifest.v11.json','early-bootstrap-gate-abort-manifest.4fba.v1.json',1),
 ('/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort.py',
  '/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort-core-4fba4c83.py',1),
 ('feb107342827abc813f5262829a77ddecb6ca1cc19e30cde2710dff540ce87f6',
  '613624f4fafb4a6cc9227cefb525dd758dde4b7e5c7d13e0610983e744d4b95f',1),
 ('/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper.py',
  '/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper-4fba4c83.py',2),
 ('bd562f25214cf337bd09c5b82c4ed866fdc8ac79ffb9da22ac8f5b380d659ac7',
  '5f160911c6ea894daca7dfe103b560c53e6d60fd5633673169158f93c921cba5',2),
 ('6eeae66cd921777b7f00c037c5fea8d78230d031533f94f6023c8bd2ec99cd3f',
  '1b737f18e97f0b9e4a4601febd0d301fcfa0eb222ab2a0995ec4fecfc62f92b2',1),
 ('24f8ba7e065c8a060b013eab8a5509c77ebeaf573619329f4a1d1ba8f83e64a6',
  '72dbf31cb148267afa6c7066ec0271af54f807ac1b9c4623f753875d85c9ee03',1),
 ('acd3065ec439790e8f1344420a79df2667fb57abdba2f5be1b77293d723821f1',
  '923ffe9ca469b16555f10659dc8cdad60ad2841e82a81b69c35cff93ee712cbb',1),
 ('eebbefd9e50842f4b96aee61299e35c2a07d697b211e70b0c2c16a6b27004fe3',
  '61c47e7fce77247ac9c5f4be3ca0cf059c77d23e61175050371b13b3c444bbac',1),
 ('12cf89c18d9cdcdfb2f5a9222edb5e9331c3ed4d3826e25120ce7bfe20b8283e',
  '1587817d4f0e589e5d1c931df345b16002892ad658386bb23f98d21de5dac085',1),
 ('130a6c1cc8aef2bc0e349b4fdc233238ea193da4fabbf9370e988e8a3233be87',
  'e3bd88a07453f54607eedbb398c31175ce77548b7d574f94359e7bdc1888ce81',1),
 ('6dcad80272677fc561485d74026f70fe3591ca6e4a8c3586ff20c1ee4121855f',
  '7b8744179ac3cdcecf01a4d7a85ac5f655b217f3b4828866681bc6775ad8ab04',1),
 ('ad0e2ad1-608f-4aee-8701-900fe6c7fd6a',
  'e306c15a-2a70-4fd3-9ca6-5a03ac23adfb',1),
)

fd=os.open(BASE,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 before=os.fstat(fd)
 if (not stat.S_ISREG(before.st_mode) or before.st_uid!=os.geteuid()
     or before.st_nlink!=1 or stat.S_IMODE(before.st_mode)!=0o755
     or any(name in ('system.posix_acl_access','system.posix_acl_default') for name in os.listxattr(fd))):
  raise SystemExit('4fba launcher: reviewed base launcher metadata differs')
 data=b''
 while len(data)<before.st_size:
  chunk=os.read(fd,min(1<<20,before.st_size-len(data)))
  if not chunk: raise SystemExit('4fba launcher: reviewed base launcher short read')
  data+=chunk
 if os.read(fd,1): raise SystemExit('4fba launcher: reviewed base launcher grew while read')
 after=os.fstat(fd);current=os.stat(BASE,follow_symlinks=False)
 identity=lambda value:(value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,
                        value.st_nlink,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
 if (identity(before)!=identity(after) or identity(after)!=identity(current)
     or hashlib.sha256(data).hexdigest()!=BASE_SHA):
  raise SystemExit('4fba launcher: reviewed base launcher identity or SHA-256 differs')
finally:
 os.close(fd)

for old,new,count in replacements:
 old_bytes=old.encode('utf-8');new_bytes=new.encode('utf-8')
 if data.count(old_bytes)!=count:
  raise SystemExit('4fba launcher: reviewed substitution boundary differs')
 data=data.replace(old_bytes,new_bytes)
 if old_bytes in data or data.count(new_bytes)<count:
  raise SystemExit('4fba launcher: operation-specific substitution differs')

# Post-transform invariants are deliberately independent of the replacement
# counts so a future base launcher cannot move the execute/default boundary.
required=(
 b'readonly OP=4fba4c832389436ba980efaa4540f6bf',
 b'mode=check-only',b'if [[ $mode == execute ]]',b'core_mode=--execute',
 b'early-bootstrap-gate-abort-manifest.4fba.v1.json',
 b'early-bootstrap-gate-abort-core-4fba4c83.py',
 b'613624f4fafb4a6cc9227cefb525dd758dde4b7e5c7d13e0610983e744d4b95f',
 b'early-bootstrap-gate-runtime-helper-4fba4c83.py',
 b'1b737f18e97f0b9e4a4601febd0d301fcfa0eb222ab2a0995ec4fecfc62f92b2',
 b'7b8744179ac3cdcecf01a4d7a85ac5f655b217f3b4828866681bc6775ad8ab04',
 b'/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/viewflow-deployment-marker',
 b'8d0945c582d249eb12b27f0e2eea109cc5fe20fe45358eacb3a43ff0d3880c54',
 b'/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/marker-reviewed-build.json',
 b'995e2a7940de17f82ef33e48ea165a8df8ba44a641c80072d711a4b0dcaefc4d',
 b'os.memfd_create',b'fcntl.F_ADD_SEALS',b'RENAME_NOREPLACE',
)
if any(item not in data for item in required):
 raise SystemExit('4fba launcher: derived launcher contract differs')
if data.index(b'mode=check-only')>data.index(b'while (($#))'):
 raise SystemExit('4fba launcher: default check-only ordering differs')
if data.index(b'if [[ $mode == execute ]]')>data.index(b'exec /usr/bin/python3 -I - "$CORE"'):
 raise SystemExit('4fba launcher: explicit execute ordering differs')

seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
memfd=os.memfd_create('viewflow-4fba-early-bootstrap-abort-launcher',os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)
try:
 view=memoryview(data)
 while view:
  written=os.write(memfd,view)
  if written<=0: raise SystemExit('4fba launcher: sealed launcher short write')
  view=view[written:]
 os.lseek(memfd,0,os.SEEK_SET)
 fcntl.fcntl(memfd,fcntl.F_ADD_SEALS,seals)
 if fcntl.fcntl(memfd,fcntl.F_GET_SEALS)!=seals:
  raise SystemExit('4fba launcher: sealed launcher flags differ')
 flags=fcntl.fcntl(memfd,fcntl.F_GETFD)
 fcntl.fcntl(memfd,fcntl.F_SETFD,flags & ~fcntl.FD_CLOEXEC)
 os.execve('/usr/bin/bash',['/usr/bin/bash',f'/proc/self/fd/{memfd}',*sys.argv[1:]],
           {'PATH':'/usr/bin:/bin'})
finally:
 os.close(memfd)
PY
