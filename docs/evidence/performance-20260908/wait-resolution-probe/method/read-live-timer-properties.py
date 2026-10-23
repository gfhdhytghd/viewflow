"""Read-only QMP query; may require the socket owner's permissions."""
from pathlib import Path
import socket,json,sys
path='/home/wilf/data/PDL_ASP_Monitor/runtime/windows-vm/qmp-vfio.sock'
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(5);s.connect(path)
f=s.makefile('rwb');record={'socket':path,'read_only_commands':True}
def read():return json.loads(f.readline())
def query(name,args=None):
    assert name in ['qmp_capabilities','query-name','query-status','query-cpus-fast','qom-get']
    d={'execute':name}
    if args:d['arguments']=args
    f.write((json.dumps(d)+'\n').encode());f.flush()
    while True:
        r=read()
        if 'event' not in r:return r
try:
    record['greeting']=read();record['capabilities']=query('qmp_capabilities')
    record['name']=query('query-name');assert record['name']['return']['name']=='Windows-AutoShop'
    record['before_status']=query('query-status');cpus=query('query-cpus-fast')['return']
    record['cpu_count']=len(cpus);record['properties']={}
    for name in ['hv-vpindex','hv-time','hv-synic','hv-stimer']:
        record['properties'][name]=query('qom-get',{'path':cpus[0]['qom-path'],'property':name})
    record['after_status']=query('query-status')
    assert record['before_status']['return']['running'] and record['after_status']['return']['running']
finally:
    f.close();s.close()
print(json.dumps(record,indent=2))
