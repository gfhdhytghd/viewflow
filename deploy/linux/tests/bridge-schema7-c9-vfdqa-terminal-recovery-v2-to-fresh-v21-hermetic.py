#!/usr/bin/env python3
"""No-host-write tests for the v2 final bridge publication primitive."""
import hashlib,importlib.util,os,sys,tempfile
from pathlib import Path
src=Path(sys.argv[1]); spec=importlib.util.spec_from_file_location('b',src); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
with tempfile.TemporaryDirectory(prefix='viewflow-c9-final-v2.') as td:
 root=Path(td); root.chmod(0o700); b.UID=os.getuid(); b.ROOT=root; b.APPROVAL=root/'approval.json'; b.FINAL=root/'final.json'; b.BRIDGE_PATH=src
 raw=b'{"fixture":true}\n'; b.create_once(b.APPROVAL,raw)
 assert b.APPROVAL.read_bytes()==raw and oct(b.APPROVAL.stat().st_mode&0o777)=='0o600'
 try: b.create_once(b.APPROVAL,raw); raise AssertionError('overwrite accepted')
 except b.Fail: pass
 try: b.create_once(root/'bad.json',b'x')
 except Exception: raise AssertionError('fresh create failed')
 print('c9 final bridge v2 hermetic publication test passed')
