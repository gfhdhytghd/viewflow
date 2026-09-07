#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH

launcher=${1:-/home/wilf/data/viewflow/deploy/launch-early-bootstrap-gate-abort-4fba4c83.sh}
die() { printf '4fba launcher checker: %s\n' "$*" >&2; exit 1; }
[[ -f $launcher && ! -L $launcher && $(stat -c %a -- "$launcher") == 755 ]] || die 'launcher identity/mode differs'
bash -n "$launcher" || die 'launcher does not parse'
need() { grep -F -- "$1" "$launcher" >/dev/null || die "missing contract: $2"; }
reject() { ! grep -E -- "$1" "$launcher" >/dev/null || die "forbidden construct: $2"; }

need "BASE='/home/wilf/data/viewflow/deploy/launch-early-bootstrap-gate-abort-2ca3f466.sh'" 'fixed reviewed base launcher'
need "BASE_SHA='e9b877a85d507033f6ffc3c9f91b3e8a0e12603b8eae118660aff7c314bb5f3f'" 'reviewed base launcher SHA'
need "('2ca3f46635b65615a1cffc1970d73911','4fba4c832389436ba980efaa4540f6bf',2)" 'exact operation substitution'
need 'early-bootstrap-gate-abort-manifest.4fba.v1.json' 'unique manifest leaf'
need 'early-bootstrap-gate-abort-core-4fba4c83.py' 'operation-specific core path'
need '613624f4fafb4a6cc9227cefb525dd758dde4b7e5c7d13e0610983e744d4b95f' 'operation-specific core SHA'
need 'early-bootstrap-gate-runtime-helper-4fba4c83.py' 'operation-specific helper path'
need '5f160911c6ea894daca7dfe103b560c53e6d60fd5633673169158f93c921cba5' 'operation helper SHA'
need '1b737f18e97f0b9e4a4601febd0d301fcfa0eb222ab2a0995ec4fecfc62f92b2' 'exact LINUX_RECOVERED state'
need '72dbf31cb148267afa6c7066ec0271af54f807ac1b9c4623f753875d85c9ee03' 'exact H binding'
need '923ffe9ca469b16555f10659dc8cdad60ad2841e82a81b69c35cff93ee712cbb' 'exact B binding'
need '61c47e7fce77247ac9c5f4be3ca0cf059c77d23e61175050371b13b3c444bbac' 'exact publish binding'
need '1587817d4f0e589e5d1c931df345b16002892ad658386bb23f98d21de5dac085' 'exact request binding'
need 'e3bd88a07453f54607eedbb398c31175ce77548b7d574f94359e7bdc1888ce81' 'exact stop-evidence binding'
need '7b8744179ac3cdcecf01a4d7a85ac5f655b217f3b4828866681bc6775ad8ab04' 'exact retained VFDQT binding'
need 'e306c15a-2a70-4fd3-9ca6-5a03ac23adfb' 'exact coordinator identity'
need '/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/viewflow-deployment-marker' 'single-link reviewed marker candidate'
need '8d0945c582d249eb12b27f0e2eea109cc5fe20fe45358eacb3a43ff0d3880c54' 'reviewed marker candidate SHA'
need '/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/marker-reviewed-build.json' 'reviewed marker provenance'
need '995e2a7940de17f82ef33e48ea165a8df8ba44a641c80072d711a4b0dcaefc4d' 'reviewed marker provenance SHA'
need "b'mode=check-only'" 'default check-only post-transform invariant'
need "b'if [[ \$mode == execute ]]'" 'explicit execute post-transform invariant'
need 'os.O_NOFOLLOW' 'stable base launcher open'
need 'before.st_nlink!=1' 'single-link base launcher requirement'
need 'os.memfd_create' 'sealed derived launcher memfd'
need 'os.MFD_ALLOW_SEALING' 'derived launcher sealing capability'
need 'fcntl.F_ADD_SEALS' 'derived launcher write/grow/shrink seal'
need 'fcntl.F_GET_SEALS' 'derived launcher seal readback'
need "os.execve('/usr/bin/bash'" 'execute sealed derived launcher'
need "{'PATH':'/usr/bin:/bin'}" 'minimal derived launcher environment'
reject '/usr/bin/ssh|systemctl|systemd-run|Start-ScheduledTask|Remove-Item' 'no live action in operation adapter'
reject '6ba741489c2f2d8c4baf69f56c25b3502ff14733145c78b9b6b2b16b5c30a378|041caabe22bb2e8b9bd7cb5020765afa1314b28ec0b5b80645b39562cfd676c1' 'normal deployment candidate must not enter abort manifest'

/usr/bin/python3 -I - "$launcher" <<'PY'
import ast,hashlib,re,sys
from pathlib import Path

launcher=Path(sys.argv[1]);source=launcher.read_text(encoding='utf-8')
assert source.count("<<'PY'\n")==1
bootstrap=source.split("<<'PY'\n",1)[1].rsplit('\nPY\n',1)[0]
compile(bootstrap,'4fba-operation-adapter','exec')
assert bootstrap.count('fcntl.fcntl(memfd,fcntl.F_ADD_SEALS,seals)')==1
assert bootstrap.count('fcntl.fcntl(memfd,fcntl.F_GET_SEALS)')==1
tree=ast.parse(bootstrap)
values={}
for node in tree.body:
    if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name):
        try: values[node.targets[0].id]=ast.literal_eval(node.value)
        except (ValueError,TypeError): pass
base=Path(values['BASE']).read_bytes()
assert hashlib.sha256(base).hexdigest()==values['BASE_SHA']
seen=set()
for old,new,count in values['replacements']:
    assert old not in seen and new not in seen and old!=new and count>0
    seen|={old,new}
    oldb=old.encode();newb=new.encode()
    assert base.count(oldb)==count
    base=base.replace(oldb,newb)
    assert oldb not in base and base.count(newb)>=count
text=base.decode()
assert text.count("<<'PY'\n")==2
blocks=text.split("<<'PY'\n")
compile(blocks[1].split('\nPY\n',1)[0],'derived-manifest-generator','exec')
compile(blocks[2].split('\nPY\n',1)[0],'derived-sealed-core-wrapper','exec')
assert 'readonly OP=4fba4c832389436ba980efaa4540f6bf' in text
assert 'readonly MANIFEST=$ROOT/early-bootstrap-gate-abort-manifest.4fba.v1.json' in text
assert 'readonly CORE=/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort-core-4fba4c83.py' in text
assert 'readonly CORE_SHA=613624f4fafb4a6cc9227cefb525dd758dde4b7e5c7d13e0610983e744d4b95f' in text
assert "op='4fba4c832389436ba980efaa4540f6bf'" in text
assert "'coordinator_state':spec(str(root/'coordinator-state.json'),'1b737f18" in text
assert "'marker_handoff':spec(str(root/'marker-handoff.json'),'72dbf31c" in text
assert "'linux_frozen':spec(str(root/'linux-frozen.json'),'923ffe9c" in text
assert "'deployment_publish':spec(str(root/'deployment-publish.json'),'61c47e7f" in text
assert "'bootstrap_request':spec(str(root/'windows-bootstrap-request.json'),'1587817d" in text
assert "'windows_stop_evidence':spec(str(root/'coordinator-state.json.windows-stop-evidence.json'),'e3bd88a0" in text
assert "'coordinator_instance_id':'e306c15a-2a70-4fd3-9ca6-5a03ac23adfb'" in text
assert "'marker':spec(marker_path,'7b874417" in text
assert "'runtime_helper':spec('/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper-4fba4c83.py'," in text
assert "'5f160911c6ea894daca7dfe103b560c53e6d60fd5633673169158f93c921cba5',755)" in text
assert 'mode=check-only' in text and text.index('mode=check-only') < text.index('while (($#))')
assert text.index('if [[ $mode == execute ]]') < text.index('core_mode=--execute')
assert '/usr/bin/ssh' not in text and 'systemctl' not in text and 'systemd-run' not in text
assert '6ba741489c2f2d8c4baf69f56c25b3502ff14733145c78b9b6b2b16b5c30a378' not in text
PY
printf '4fba early bootstrap gate launcher checker passed\n'
