#!/usr/bin/env python3
"""Hermetic QUIC integration: fake native adapters, no desktop APIs or input."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'platform/desktop-app'))
from pairing_protocol import new_key, issue_pair, private_key_pem, public_key

NATIVE = r'''#!/usr/bin/env python3
import json, os, struct, sys
from pathlib import Path
role=Path(__file__).name
log=Path(__file__).with_suffix('.log')
seq=0
held=set()
def emit(kind, a=0, b=0, lease=1):
    global seq
    seq+=1
    data=struct.pack('<IQQIiiii',2,lease,seq,kind,a,b,0,0)
    sys.stdout.buffer.write(struct.pack('<I',len(data))+data);sys.stdout.buffer.flush()
def note(value):
    with log.open('a') as out:out.write(value+'\n')
emit(102,1,1)
while True:
    prefix=sys.stdin.buffer.read(4)
    if not prefix:break
    data=sys.stdin.buffer.read(struct.unpack('<I',prefix)[0])
    _,lease,sequence,kind,a,b,c,d=struct.unpack('<IQQIiiii',data)
    if kind==102 and role=='native-a':emit(100,0,30000)
    elif kind==200:
        note('captured');emit(4,29,1);emit(2,272,1);emit(1,20000,30000)
        if os.environ.get('VIEWFLOW_TEST_DISCONNECT')=='1':note('disconnected');break
        emit(101);note('returned')
    elif kind==201:note('entered')
    elif kind in (2,4):
        note(f'input {kind} {a} {b}')
        if b:held.add((kind,a))
        else:held.discard((kind,a))
    elif kind==202:
        for k,a in sorted(held):note(f'release {k} {a}')
        held.clear();note('released');emit(204,lease=lease);break
'''

def port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(('127.0.0.1',0));return sock.getsockname()[1]

def run(binary, disconnect):
    with tempfile.TemporaryDirectory(prefix='viewflow-handoff-transport-') as temporary:
        root=Path(temporary)
        ak,bk=new_key(),new_key()
        certs=issue_pair('a'*32,ak,'b'*32,public_key(bk))
        ports=[port(),port()]
        assert ports[0]!=ports[1]
        processes=[]
        try:
            for index,(label,key,certificate) in enumerate((('a',ak,certs['local_certificate']),('b',bk,certs['peer_certificate']))):
                directory=root/label;directory.mkdir()
                native=directory/('native-'+label);native.write_text(NATIVE);native.chmod(0o700)
                for name,text in [('cert.pem',certificate),('key.pem',private_key_pem(key)),('ca.pem',certs['authority'])]:
                    (directory/name).write_text(text)
                config=dict(bind=f'127.0.0.1:{ports[index]}',remote=f'127.0.0.1:{ports[1-index]}',
                    server_name='vf-'+('b' if label=='a' else 'a')*32+'.local',
                    device_id=label*32,peer_id=('b' if label=='a' else 'a')*32,
                    certificate=str(directory/'cert.pem'),private_key=str(directory/'key.pem'),certificate_authority=str(directory/'ca.pem'),
                    native=str(native),local=dict(x=0,y=0,width=100,height=80),
                    peer=dict(x=100 if label=='a' else -100,y=0,width=100,height=80))
                path=directory/'config.json';path.write_text(json.dumps(config))
                log=(directory/'transport.log').open('w')
                environment=dict(os.environ,TMPDIR=str(directory),TEMP=str(directory),TMP=str(directory),VIEWFLOW_TEST_DISCONNECT='1' if disconnect else '0')
                processes.append((subprocess.Popen([binary,'--config',path],env=environment,stdout=log,stderr=log),log))
            deadline=time.monotonic()+15
            while time.monotonic()<deadline:
                a=(root/'a/native-a.log').read_text() if (root/'a/native-a.log').exists() else ''
                b=(root/'b/native-b.log').read_text() if (root/'b/native-b.log').exists() else ''
                if ('disconnected' if disconnect else 'released') in a and 'released' in b:break
                time.sleep(.02)
            else:
                raise AssertionError('\n'.join((root/x/'transport.log').read_text() for x in ('a','b')))
            assert 'captured' in a and ('disconnected' if disconnect else 'returned') in a and 'input ' not in a, a
            assert all(line in b for line in ('entered','input 4 29 1','input 2 272 1','release 4 29','release 2 272','released')), b
            print('PASS: mTLS QUIC captured -> entered -> ordered key/button -> '+('disconnect' if disconnect else 'return')+' -> released; fake adapters only')
        finally:
            for process,_ in processes:
                if process.poll() is None:process.send_signal(signal.SIGINT)
            for process,log in processes:
                try:process.wait(timeout=8)
                except subprocess.TimeoutExpired:process.kill();process.wait()
                log.close()
if __name__=='__main__':
    binary=Path(sys.argv[1]).resolve()
    for disconnect in (False,True):run(binary,disconnect)
