#!/usr/bin/env python3
"""Pure Python fake-child/fake-QMP integration test; no VM or GPU."""
import array
import importlib.util
import fcntl
import json
import mmap
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time


def wait_for(predicate, process, seconds=8):
    deadline = time.monotonic()+seconds
    while not predicate():
        if process.poll() is not None or time.monotonic() >= deadline:
            raise AssertionError('Owned test child exited or condition deadline elapsed')
        time.sleep(.02)


def main():
    launcher = Path(__file__).with_name('qemu-dma-banks-launch.py')
    sys.dont_write_bytecode=True
    spec=importlib.util.spec_from_file_location('banks_keeper_test',launcher)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    with mmap.mmap(-1,1<<20) as memory:
        pump=module.MappingPump(memory,'unused')
        assert pump.poll_interval()==.05
        struct.pack_into('<Q',memory,2176,1)
        assert pump.poll_interval()==.001
        pump.next_attempt[(0,0)]=time.monotonic()+60
        assert pump.poll_interval()==.05
        struct.pack_into('<Q',memory,2240,1)
        assert pump.poll_interval()==.05
    with tempfile.TemporaryDirectory(prefix='viewflow-banks-test-') as directory:
        root = Path(directory)
        controlpath, endpoint, qmp = root/'control', root/'banks.sock', root/'qmp.sock'
        ready, finish = root/'ready', root/'finish'
        before = struct.pack('<QQI4II', 0x324B4E4142465656, 1 << 30, 7, 11, 22, 33, 44, 0)
        with controlpath.open('w+b') as stream:
            stream.truncate(1 << 20)
            stream.seek(1024)
            stream.write(before)
        stop = threading.Event()
        operations = []
        allow = threading.Event()
        def server():
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(qmp));listener.listen();listener.settimeout(.1)
                while not stop.is_set():
                    try:connection,_ = listener.accept()
                    except socket.timeout:continue
                    with connection:
                        connection.settimeout(.2)
                        connection.sendall(b'{"QMP":{}}\n')
                        buffer=b''
                        while not stop.is_set():
                            try:data=connection.recv(4096)
                            except socket.timeout:continue
                            if not data:break
                            buffer+=data
                            while b'\n' in buffer:
                                line,buffer=buffer.split(b'\n',1);request=json.loads(line)
                                result={'id':request['id'],'return':{}}
                                if request['execute']=='qom-set':
                                    operations.append(request['arguments'])
                                    if not allow.is_set():
                                        result={'id':request['id'],'error':{'class':'GenericError','desc':'test transient'}}
                                connection.sendall(json.dumps(result).encode()+b'\n')
        thread=threading.Thread(target=server,daemon=True);thread.start()
        code=('import os,sys,pathlib,time; f=[os.open(v,os.O_RDWR) for v in sys.argv[3:]]; '
              'assert len(f)==4 and all(os.fstat(v).st_size==1<<30 for v in f); '
              'pathlib.Path(sys.argv[1]).write_text("ready");\n'
              'while not pathlib.Path(sys.argv[2]).exists():time.sleep(.02)')
        process=subprocess.Popen([sys.executable,str(launcher),'--control',str(controlpath),
                 '--socket',str(endpoint),'--qmp',str(qmp),'--',sys.executable,'-c',code,
                 str(ready),str(finish),*[f'@VIEWFLOW_DMA_BANK{i}@' for i in range(4)]],
                 stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        received=[]
        try:
            wait_for(ready.exists,process)
            # Existing Linux receiver must still obtain its exclusive control lock.
            with controlpath.open('r+b') as receiver:
                fcntl.flock(receiver.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(receiver.fileno(), fcntl.LOCK_UN)
            with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
                connection.connect(str(endpoint));connection.sendall(b'GET')
                data,ancillary,_,_=connection.recvmsg(4096,socket.CMSG_SPACE(16))
                metadata=json.loads(data)
                for level,kind,contents in ancillary:
                    if level==socket.SOL_SOCKET and kind==socket.SCM_RIGHTS:
                        values=array.array('i');values.frombytes(contents);received.extend(values)
            assert len(received)==4 and metadata['version']==2
            assert all(fcntl.fcntl(fd,fcntl.F_GET_SEALS)==6 for fd in received)
            assert [os.fstat(fd).st_ino for fd in received]==metadata['inodes']
            with controlpath.open('r+b') as stream,mmap.mmap(stream.fileno(),1<<20) as control:
                assert control[1024:1060]==before[:36] and struct.unpack_from('<I',control,1060)[0]==6
                fields=struct.unpack_from('<QIIQQIIII4Q4Q2Q',control,2048)
                assert fields[:9]==(0x31414D4442465656,1,1,metadata['generation'],1<<30,64<<20,16,0,10)
                assert list(fields[9:13])==metadata['devices'] and list(fields[13:17])==metadata['inodes']
                assert control[2176:2368]==bytes(192)
                time.sleep(.15);assert operations==[]
                struct.pack_into('<Q',control,2176+8,5)
                wait_for(lambda:struct.unpack_from('<Q',control,2304+8)[0]!=0,process)
                assert struct.unpack_from('<Q',control,2240+8)[0]==0
                allow.set()
                wait_for(lambda:struct.unpack_from('<Q',control,2240+8)[0]==5,process)
                assert struct.unpack_from('<Q',control,2304+8)[0]==0
                assert all(v['path'] in ('/objects/viewflow_dma_bank1_segment0','/objects/viewflow_dma_bank1_segment2') and v['value']==64<<20 for v in operations)
                assert all(struct.unpack_from('<Q',control,2240+b*8)[0]==0 for b in [0,2,3])
                assert control[2048:2176]==struct.pack('<QIIQQIIII4Q4Q2Q',*fields)
            finish.touch();out,err=process.communicate(timeout=5)
            assert process.returncode==0,(out,err)
            assert not endpoint.exists()
            print(json.dumps({'status':'passed','scope':'fake child/QMP only','fd_count':4,
                  'abi_bytes':320,'requests_independent':True,'transient_retry':True,
                  'metadata_immutable':True,'socket_cleanup':True,'vm_or_gpu_used':False}))
        finally:
            finish.touch()
            process.wait(timeout=5)
            for fd in received:os.close(fd)
            stop.set();thread.join(timeout=2)


if __name__=='__main__':main()
