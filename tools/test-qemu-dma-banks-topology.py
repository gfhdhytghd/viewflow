#!/usr/bin/env python3
"""Stopped, diskless TCG Q35 topology test; no production QMP, KVM or GPU."""
import argparse
import array
import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode=True

def module(name,file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file))
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qemu',required=True)
    args=parser.parse_args()
    helper=module('topology_qmp','test-qemu-demand-dma.py')
    inspector=module('topology_inspector','dma-memfd-client.py')
    report={'status':'failed','guest_cpus_started':False,'gpu_or_vfio_used':False,
            'firmware_resource_assignment_verified':False,'qmp':[]}
    with tempfile.TemporaryDirectory(prefix='viewflow-topology-test-') as directory:
        root=Path(directory);control=root/'control';qmp_path=root/'qmp';broker=root/'banks'
        with control.open('wb') as stream:
            stream.truncate(1<<20);stream.seek(1024)
            stream.write(struct.pack('<QQI4II',0x324B4E4142465656,1<<30,0,6<<16,7<<16,8<<16,9<<16,0))
        command=[str(Path(args.qemu).resolve()),'-L','/usr/share/qemu','-machine','q35,accel=tcg',
                 '-S','-nodefaults','-display','none','-m','128M','-qmp',f'unix:{qmp_path},server=on,wait=off']
        for bank in range(4):
            ident=f'viewflow_cpu_only_slot{bank}'
            command+=['-object',f'memory-backend-file,id={ident},size=1G,mem-path=@VIEWFLOW_DMA_BANK{bank}@,share=on,reserve=off,prealloc=off,x-use-canonical-path-for-ramblock-id=off',
                      '-device',f'ivshmem-plain,memdev={ident},bus=pcie.0,addr=0x{6+bank:x}']
            for segment in range(16):
                ordinal=bank*16+segment;slot=10+ordinal//8;function=ordinal%8
                ident=f'viewflow_dma_bank{bank}_segment{segment}'
                command+=['-object',f'memory-backend-file,id={ident},size=64M,offset={segment*64}M,mem-path=@VIEWFLOW_DMA_BANK{bank}@,share=on,reserve=off,prealloc=off,x-viewflow-dma-managed=on,x-use-canonical-path-for-ramblock-id=off',
                          '-device',f'ivshmem-plain,id=vf_dma_b{bank}s{segment},memdev={ident},bus=pcie.0,addr=0x{slot:x}.{function}'+(',multifunction=on' if function==0 else '')]
        process=None;connection=None;received=[];qmp=None
        with (root/'stderr').open('w+b') as errors:
            try:
                process=subprocess.Popen([sys.executable,str(Path(__file__).with_name('qemu-dma-banks-launch.py')),
                    '--control',str(control),'--socket',str(broker),'--qmp',str(qmp_path),'--',*command],stderr=errors)
                deadline=time.monotonic()+30
                while True:
                    if process.poll() is not None or time.monotonic()>deadline:raise RuntimeError('Owned topology startup failed')
                    connection=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
                    try:connection.connect(str(qmp_path));break
                    except (FileNotFoundError,ConnectionRefusedError):connection.close();connection=None;time.sleep(.02)
                qmp=helper.QMP(connection,deadline,report['qmp'])
                devices=qmp.call('query-pci')
                entries=[d for bus in devices for d in bus['devices'] if d.get('qdev_id','').startswith('vf_dma_b')]
                addresses={(d['bus'],d['slot'],d['function']) for d in entries}
                expected={(0,10+i//8,i%8) for i in range(64)}
                if addresses!=expected or len(entries)!=64:raise AssertionError('64-function topology mismatch')
                prefixes=[qmp.get(f'viewflow_dma_bank{b}_segment{s}','x-viewflow-dma-prefix') for b in range(4) for s in range(16)]
                if any(prefixes):raise AssertionError('Unexpected populated prefix')
                with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
                    client.connect(str(broker));client.sendall(b'GET')
                    data,anc,_,_=client.recvmsg(4096,socket.CMSG_SPACE(16));metadata=json.loads(data)
                    for level,kind,contents in anc:
                        if level==socket.SOL_SOCKET and kind==socket.SCM_RIGHTS:
                            values=array.array('i');values.frombytes(contents);received.extend(values)
                if len(received)!=4:raise AssertionError('Expected four bank fds')
                resident=[inspector.inspect(fd)['resident_bytes'] for fd in received]
                if any(resident):raise AssertionError(f'Unexpected residency {resident}')
                report.update({'segments':len(entries),'bdfs':sorted(addresses),'prefixes':prefixes,
                               'resident_bytes_by_bank':resident,'metadata':metadata})
                qmp.call('quit');process.wait(timeout=5)
                if process.returncode:raise AssertionError('Owned launcher failed')
                report['status']='passed'
            except Exception as error:
                report['error']=f'{type(error).__name__}: {error}'
                if process is not None and process.poll() is None:
                    if qmp:
                        try:qmp.call('quit')
                        except Exception:pass
                    if process.poll() is None:process.terminate()
                    process.wait(timeout=5)
            finally:
                if connection:connection.close()
                for fd in received:os.close(fd)
                errors.seek(0);report['stderr']=errors.read().decode(errors='replace')
    print(json.dumps(report,indent=2))
    return 0 if report['status']=='passed' else 1

if __name__=='__main__':raise SystemExit(main())
