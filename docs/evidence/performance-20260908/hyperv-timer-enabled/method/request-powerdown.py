"""Request ACPI guest shutdown of the named VM; never quit or kill QEMU."""
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect('/home/wilf/data/PDL_ASP_Monitor/runtime/windows-vm/qmp-vfio.sock')
f = s.makefile('rwb')
def receive(): return json.loads(f.readline())
def query(command):
    f.write((json.dumps({'execute':command})+'\n').encode()); f.flush()
    while True:
        r=receive()
        if 'event' not in r:
            if 'error' in r: raise RuntimeError(r)
            return r
try:
    receive(); query('qmp_capabilities')
    name=query('query-name'); assert name['return']['name']=='Windows-AutoShop'
    status=query('query-status'); assert status['return']['running']
    result=query('system_powerdown')
    print(json.dumps(dict(name=name,status=status,acpi_powerdown=result,forced=False),indent=2))
finally:
    f.close(); s.close()
