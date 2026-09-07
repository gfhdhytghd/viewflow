#!/usr/bin/env python3
"""Create-once approval for c9 schema7 committed-abort recovery-v2."""

import argparse,ctypes,hashlib,json,os,re,stat,sys
from pathlib import Path

OP="c9b05e9bea4140d69f9d137a0f992ba0"
ROOT=Path("/home/wilf/.local/state/viewflow/deployments")/OP
OUTPUT=ROOT/"failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-execution-approval.json"
MANIFEST=Path("/home/wilf/data/viewflow/deploy/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-manifest.json")
GATE=Path("/home/wilf/data/viewflow/deploy/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-gate.py")
LAUNCHER=Path("/home/wilf/data/viewflow/deploy/launch-failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2.sh")
MANIFEST_SHA="919bd49f40f4fe5cb140f22576613bc3e76a4489456e780956999c0cbfdd5d83"
GATE_SHA="a897d0d0f9084d1c2b0f8429ada1da8a5621d796cd3458be1b4a37d6b62b9a0e"
LAUNCHER_SHA="4450805d8a31c5c3194a687590088bd65255061e649b97983f87806cd5aeb657"
SHA=re.compile(r"[0-9a-f]{64}\Z")
UTC=re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\Z")

def identity(v): return (v.st_dev,v.st_ino,v.st_mode,v.st_uid,v.st_gid,v.st_nlink,v.st_size,v.st_mtime_ns,v.st_ctime_ns)
def stable_read(path,expected,mode):
    if not SHA.fullmatch(expected): raise RuntimeError("publisher not refrozen")
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd); named=os.stat(path,follow_symlinks=False)
        if not(identity(before)==identity(named) and before.st_uid==os.geteuid() and before.st_nlink==1 and stat.S_ISREG(before.st_mode) and stat.S_IMODE(before.st_mode)==mode):
            raise RuntimeError("publisher input metadata differs")
        raw=os.read(fd,before.st_size+1)
        if len(raw)!=before.st_size or identity(os.fstat(fd))!=identity(before) or hashlib.sha256(raw).hexdigest()!=expected:
            raise RuntimeError("publisher input changed")
        return raw
    finally: os.close(fd)

def create_once(raw):
    parent=os.open(ROOT,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
    tmp="."+OUTPUT.name+".tmp."+str(os.getpid())+"."+os.urandom(8).hex()
    try:
        pst=os.fstat(parent); named=os.stat(ROOT,follow_symlinks=False)
        if not(identity(pst)==identity(named) and pst.st_uid==os.geteuid() and stat.S_IMODE(pst.st_mode)==0o700): raise RuntimeError("approval parent differs")
        try: os.stat(OUTPUT.name,dir_fd=parent,follow_symlinks=False)
        except FileNotFoundError: pass
        else: raise RuntimeError("recovery-v2 approval exists")
        fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC,0o600,dir_fd=parent)
        try: os.write(fd,raw); os.fsync(fd)
        finally: os.close(fd)
        if ctypes.CDLL(None,use_errno=True).renameat2(parent,os.fsencode(tmp),parent,os.fsencode(OUTPUT.name),1)!=0: raise RuntimeError("approval no-replace failed")
        os.fsync(parent)
    finally:
        try: os.unlink(tmp,dir_fd=parent)
        except FileNotFoundError: pass
        os.close(parent)

def main():
    p=argparse.ArgumentParser(); modes=p.add_mutually_exclusive_group(required=True)
    modes.add_argument("--check-only",action="store_true"); modes.add_argument("--publish",action="store_true")
    p.add_argument("--approved-at-utc",default=""); a=p.parse_args()
    stable_read(MANIFEST,MANIFEST_SHA,0o600); stable_read(GATE,GATE_SHA,0o700); stable_read(LAUNCHER,LAUNCHER_SHA,0o700)
    if OUTPUT.exists() or OUTPUT.is_symlink(): raise RuntimeError("recovery-v2 approval is not fresh")
    if a.check_only:
        if a.approved_at_utc: raise RuntimeError("check-only rejects timestamp")
        print("c9b05e9 recovery-v2 approval publisher check passed; no write"); return
    if not UTC.fullmatch(a.approved_at_utc): raise RuntimeError("canonical millisecond UTC required")
    committed={"authorization_sha256":"598a11e781506a9cc2267d266d08df0c0a35db056595ff44fd993d8e8c5b45ad",
      "abort_receipt_sha256":"b9baa81d2b7c356be6c699736db2befdf7e3b4a554b954c99279ace6d57472bd",
      "transition_sha256":"14345a57e9c94c07916ea5b4bcc390fe8ceae6f207723b9bda414a758e11f0c7",
      "linux_v13_started_sha256":"0f9d013499dd45e94fc0efbb7e907c965165296f998276bb6505fafb86d78c45",
      "windows_v13_started_sha256":"e4037a8f6024e49169dba1ee094de7a9a90ff2180636c7b6cf098ebf401003a5",
      "authenticated_v13_peer_sha256":"39c37a58ad970d21731cfb78e85184d37799e41a3e7cf62b74e67e068aa82e8a"}
    value={"schema_version":2,"state":"viewflow-c9b05e9-schema7-abort-recovery-v2-execution-approved",
      "approved":True,"operation_id":OP,"manifest_sha256":MANIFEST_SHA,"gate_sha256":GATE_SHA,
      "launcher_sha256":LAUNCHER_SHA,"predecessor_approval_sha256":"26b75c5187b843db57a0da262f5ebb0f4aec660ee60c4231fb707c034c6d5cb4",
      "coordinator_dispatch_forbidden":True,"abort_redispatch_forbidden":True,"only_pinned_marker_query":True,
      **committed,"durable_vfdqa_sha256":"56ae0daa3327e2ee469376968d59bd02086f1730b0f3fc1bd0459dca9422a67f",
      "retired_claim_sha256":"9bc030e47e4d148341cf3cf540f318d291614b39769590a1035e2dcbc336f90a",
      "publication_method":"create-once-no-replace-and-parent-fsync","approved_at_utc":a.approved_at_utc}
    create_once((json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode())
    print("c9b05e9 recovery-v2 approval published create-once")

if __name__=="__main__":
    try: main()
    except (OSError,RuntimeError,ValueError) as e:
        print("c9b05e9 recovery-v2 approval: "+str(e),file=sys.stderr); raise SystemExit(1)
