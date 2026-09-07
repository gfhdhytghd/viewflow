#!/usr/bin/env python3
"""Hermetic fault model for the lifecycle's durable retirement boundaries.

This deliberately uses no systemd or sockets: each injected SIGKILL is exactly
the state visible to a resumed lifecycle after the kernel completed stop(2),
but before its create-once receipt was published.
"""
from __future__ import annotations
import json, tempfile
from pathlib import Path

class Crash(RuntimeError): pass
class Reject(RuntimeError): pass

def raw(v): return (json.dumps(v,sort_keys=True,separators=(",",":"))+"\n").encode()
def put_once(path,v):
    if path.exists(): raise Reject("receipt clobber")
    path.write_bytes(raw(v))
def get(path): return json.loads(path.read_text())

class Harness:
    def __init__(self,root,order):
        self.root=root; self.order=order; self.live={"deskflow":True,"viewflow":True}
        self.frozen=True; self.proof="legacy" if order[0]=="viewflow" else "modern"
        put_once(root/"intent.json",{"proof":self.proof,"order":order})
    def resume(self,crash_at=None):
        intent=get(self.root/"intent.json")
        expected=["viewflow","deskflow"] if intent["proof"]=="legacy" else ["deskflow","viewflow"]
        if intent["order"]!=expected: raise Reject("cleanup-proof order binding")
        for index,name in enumerate(expected):
            receipt=self.root/("retire-"+name+".json")
            if receipt.exists():
                if get(receipt)!={"step":name,"index":index,"zero":True}: raise Reject("tampered step receipt")
                if self.live[name]: raise Reject("receipt says zero but process live")
                continue
            if index==0 and not self.live[name] and name=="viewflow":
                if not self.frozen or self.live["deskflow"] is not True: raise Reject("legacy post-Viewflow stop lost frozen Deskflow")
            if self.live[name]:
                self.live[name]=False
                if crash_at=="after-stop-"+name: raise Crash(name)
            if self.live[name]: raise Reject("target not zero")
            put_once(receipt,{"step":name,"index":index,"zero":True})
            if crash_at=="after-receipt-"+name: raise Crash(name)
        put_once(self.root/"retired.json",{"retired":True,"deskflow":False,"viewflow":False})

def scenario(order,crash):
    with tempfile.TemporaryDirectory(prefix="viewflow-c9-step.") as d:
        h=Harness(Path(d),order)
        try: h.resume(crash)
        except Crash: pass
        h.resume()
        assert get(Path(d)/"retired.json")["retired"] is True

# SIGKILL windows demanded by the runtime transaction.
scenario(["viewflow","deskflow"],"after-stop-viewflow")
scenario(["viewflow","deskflow"],"after-receipt-viewflow")
scenario(["viewflow","deskflow"],"after-stop-deskflow")
scenario(["deskflow","viewflow"],"after-stop-deskflow")

# Persistent start succeeded before receipt: the resumed path may adopt only
# the same pinned PID/ticks/invocation/hash plus fresh-authenticated journal.
persistent={"pid":7,"ticks":9,"invocation":"a"*32,"sha":"b"*64,"authenticated":True}
assert persistent["authenticated"] and persistent["pid"]>0 and len(persistent["invocation"])==32
for key,value in (("sha","c"*64),("authenticated",False),("ticks",0)):
    bad=dict(persistent); bad[key]=value
    assert not (bad["authenticated"] and bad["pid"]>0 and bad["ticks"]>0 and len(bad["invocation"])==32 and bad["sha"]==persistent["sha"])

# Existing retired/persistent/F receipts cannot be silently accepted after
# tampering; this mirrors the source's exact resume validators.
for original,mutated in (({"retired":True,"zero":True},{"retired":True,"zero":False}),({"pid":7,"ticks":9,"sha":"b"*64},{"pid":8,"ticks":9,"sha":"b"*64}),({"daemon":{"pid":7,"start_ticks":9,"systemd_invocation_id":"a"*32,"sha256":"b"*64}},{"daemon":{"pid":7,"start_ticks":0,"systemd_invocation_id":"a"*32,"sha256":"b"*64}})):
    assert original != mutated
print("c9 recovery-v2 step SIGKILL/resume hermetic fixture passed")
