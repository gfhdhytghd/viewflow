#!/usr/bin/env bash
set -euo pipefail

launcher=/home/wilf/data/viewflow/deploy/launch-failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2.sh
exec /usr/bin/env -i HOME=/home/wilf USER=wilf LOGNAME=wilf PATH=/usr/bin:/bin \
  LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONHASHSEED=0 \
  /usr/bin/python3 -I - "$launcher" "$@" <<'PY'
import fcntl,hashlib,os,re,stat,sys

GATE = "/home/wilf/data/viewflow/deploy/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-gate.py"
MANIFEST = "/home/wilf/data/viewflow/deploy/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-manifest.json"
EXPECTED_LAUNCHER = "/home/wilf/data/viewflow/deploy/launch-failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2.sh"
GATE_SHA = "a897d0d0f9084d1c2b0f8429ada1da8a5621d796cd3458be1b4a37d6b62b9a0e"
MANIFEST_SHA = "919bd49f40f4fe5cb140f22576613bc3e76a4489456e780956999c0cbfdd5d83"
SHA = re.compile(r"[0-9a-f]{64}\Z")

def identity(v):
    return (v.st_dev,v.st_ino,v.st_mode,v.st_uid,v.st_gid,v.st_nlink,v.st_size,v.st_mtime_ns,v.st_ctime_ns)

def stable_read(path,expected,mode):
    if not SHA.fullmatch(expected): raise SystemExit("launcher is not refrozen")
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd); named=os.stat(path,follow_symlinks=False)
        if not (identity(before)==identity(named) and stat.S_ISREG(before.st_mode)
                and before.st_uid==os.geteuid() and before.st_nlink==1
                and stat.S_IMODE(before.st_mode)==mode
                and not any(x in ("system.posix_acl_access","system.posix_acl_default") for x in os.listxattr(fd))):
            raise SystemExit("launcher input metadata differs")
        raw=os.read(fd,before.st_size+1)
        if len(raw)!=before.st_size or identity(os.fstat(fd))!=identity(before) or hashlib.sha256(raw).hexdigest()!=expected:
            raise SystemExit("launcher input changed")
        return raw
    finally: os.close(fd)

def seal(name,raw,mode):
    fd=os.memfd_create(name,os.MFD_ALLOW_SEALING); view=memoryview(raw)
    while view:
        count=os.write(fd,view)
        if count<=0: raise SystemExit("memfd short write")
        view=view[count:]
    os.fchmod(fd,mode)
    seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
    fcntl.fcntl(fd,fcntl.F_ADD_SEALS,seals)
    if fcntl.fcntl(fd,fcntl.F_GET_SEALS)!=seals: raise SystemExit("memfd seal differs")
    os.set_inheritable(fd,True); return fd

if os.geteuid()!=1000 or len(sys.argv) not in (3,4): raise SystemExit(64)
launcher_path,mode=sys.argv[1],sys.argv[2]
if launcher_path!=EXPECTED_LAUNCHER: raise SystemExit("launcher self path differs")
if mode not in ("--offline-check","--execute","--resume"): raise SystemExit(64)
if mode in ("--execute","--resume"):
    if len(sys.argv)!=4 or not SHA.fullmatch(sys.argv[3]): raise SystemExit(64)
elif len(sys.argv)!=3: raise SystemExit(64)
gate=stable_read(GATE,GATE_SHA,0o700); manifest=stable_read(MANIFEST,MANIFEST_SHA,0o600)
source=os.open(launcher_path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try: launcher_raw=os.read(source,os.fstat(source).st_size+1)
finally: os.close(source)
launcher_sha=hashlib.sha256(launcher_raw).hexdigest(); stable_read(launcher_path,launcher_sha,0o700)
gfd=seal("viewflow-c9-recovery-v2-gate",gate,0o700)
mfd=seal("viewflow-c9-recovery-v2-manifest",manifest,0o600)
lfd=seal("viewflow-c9-recovery-v2-launcher",launcher_raw,0o700)
argv=["/usr/bin/python3","-I",f"/proc/self/fd/{gfd}","--manifest",f"/proc/self/fd/{mfd}",
      "--manifest-sha256",MANIFEST_SHA,"--gate-sha256",GATE_SHA,
      "--launcher-sha256",launcher_sha,"--launcher-sealed-fd",f"/proc/self/fd/{lfd}",mode]
if mode in ("--execute","--resume"): argv.extend(["--approval-sha256",sys.argv[3]])
env={"HOME":"/home/wilf","USER":"wilf","LOGNAME":"wilf","PATH":"/usr/bin:/bin",
     "LANG":"C.UTF-8","LC_ALL":"C.UTF-8","PYTHONHASHSEED":"0"}
os.execve("/usr/bin/python3",argv,env)
PY
