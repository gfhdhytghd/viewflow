#!/usr/bin/env python3
"""Generate reviewable candidate/backup only; never installs or starts a VM."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',required=True)
    p.add_argument('--expected-sha256',required=True)
    p.add_argument('--output-dir',required=True)
    p.add_argument('--launcher',required=True)
    p.add_argument('--qemu',required=True)
    p.add_argument('--socket',default='/run/viewflow-dma-banks.sock')
    p.add_argument('--control',default='/dev/shm/viewflow-frames')
    a=p.parse_args()
    source=Path(a.source).read_bytes();digest=hashlib.sha256(source).hexdigest()
    if digest!=a.expected_sha256:raise ValueError('Source override hash changed')
    text=source.decode();logical=text.replace('\\\n',' ')
    starts=[v[len('ExecStart='):] for v in logical.splitlines() if v.startswith('ExecStart=') and v!='ExecStart=']
    if len(starts)!=1:raise ValueError('Expected one nonempty ExecStart')
    words=shlex.split(starts[0])
    old_socket=words[words.index('--socket')+1] if '--socket' in words else None
    if '--' not in words:raise ValueError('Expected existing explicit scratch keeper command')
    words=words[words.index('--')+1:];words[0]=a.qemu
    result=[];cpu=set();i=0;qmp=None
    while i<len(words):
        if words[i] in ('-object','-device'):
            key,value=words[i:i+2]
            if re.search(r'(?:^|,)(?:id|memdev)=(?:viewflow_dma_segment|vf_dma_segment)\d+(?:,|$)',value):
                i+=2;continue
            match=re.search(r'(?:^|,)id=viewflow_cpu_only_slot([0-3])(?:,|$)',value)
            if key=='-object' and match:
                bank=int(match[1]);cpu.add(bank)
                value=re.sub(r'mem-path=[^,]+',f'mem-path=@VIEWFLOW_DMA_BANK{bank}@',value)
                if 'reserve=' not in value:value+=',reserve=off'
            if key=='-device' and 'addr=' in value:
                address=re.search(r'(?:^|,)addr=(0x[0-9a-fA-F]+|[0-9]+)(?:[.,]|$)',value)
                if address and 10<=int(address[1],0)<=17:
                    raise ValueError('Candidate segment PCI slots overlap retained device')
            result += [key,value];i+=2;continue
        if words[i]=='-qmp':
            qmp=words[i+1]
        result.append(words[i]);i+=1
    if cpu!={0,1,2,3}:raise ValueError('Missing existing four CPU bank objects')
    if not qmp or not qmp.startswith('unix:'):raise ValueError('Missing Unix QMP endpoint')
    qmp=qmp[5:].split(',')[0]
    topology=[]
    for b in range(4):
        for s in range(16):
            ordinal=b*16+s;slot=10+ordinal//8;function=ordinal%8
            ident=f'viewflow_dma_bank{b}_segment{s}'
            result += ['-object',f'memory-backend-file,id={ident},size=64M,offset={s*64}M,mem-path=@VIEWFLOW_DMA_BANK{b}@,share=on,reserve=off,prealloc=off,x-use-canonical-path-for-ramblock-id=off,x-viewflow-dma-managed=on',
                       '-device',f'ivshmem-plain,id=vf_dma_b{b}s{s},memdev={ident},bus=pcie.0,addr=0x{slot:x}.{function}'+(',multifunction=on' if function==0 else '')]
            topology.append({'bank':b,'segment':s,'bus':0,'slot':slot,'function':function,'offset':s*(64<<20)})
    command=['/usr/bin/python3',a.launcher,'--control',a.control,'--socket',a.socket,'--qmp',qmp,'--owner-uid','1000','--',*result]
    def unit_quote(v):
        return '"'+v.replace('\\','\\\\').replace('"','\\"').replace('%','%%').replace('$','$$')+'"'
    newstart='ExecStart='+' '.join(unit_quote(v) for v in command)
    lines=logical.splitlines()
    if old_socket:
        old_cleanup='ExecStartPre=/usr/bin/rm -f '+old_socket
        if lines.count(old_cleanup)!=1:
            raise ValueError('Expected exact existing scratch socket cleanup command')
        lines=[('ExecStartPre=/usr/bin/rm -f '+unit_quote(a.socket)) if v==old_cleanup else v for v in lines]
    output='\n'.join(newstart if v.startswith('ExecStart=') and v!='ExecStart=' else v for v in lines)+'\n'
    directory=Path(a.output_dir);directory.mkdir(parents=True,exist_ok=False)
    (directory/'source.override.conf').write_bytes(source)
    (directory/'candidate.override.conf').write_text(output)
    (directory/'manifest.json').write_text(json.dumps({'source':str(Path(a.source).resolve()),'source_sha256':digest,'command':command,'topology':topology,'segment_bar_bytes':4<<30,'retained_cpu_bank_bar_bytes':4<<30,'hardware_resource_allocation_verified':False,'deployment_performed':False},indent=2)+'\n')
    print(json.dumps({'output_dir':str(directory),'source_sha256':digest,'segments':len(topology),'deployed':False}))


if __name__=='__main__':main()
