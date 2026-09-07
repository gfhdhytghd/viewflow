#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
export PYTHONDONTWRITEBYTECODE=1

adapter=${1:-/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort-core-4fba4c83.py}
die() { printf '4fba core checker: %s\n' "$*" >&2; exit 1; }
[[ -f $adapter && ! -L $adapter && $(stat -c %a -- "$adapter") == 755 ]] || die 'adapter identity/mode differs'
need() { grep -F -- "$1" "$adapter" >/dev/null || die "missing contract: $2"; }
reject() { ! grep -E -- "$1" "$adapter" >/dev/null || die "forbidden construct: $2"; }

need 'GENERIC_CORE = "/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort.py"' 'fixed generic core path'
need 'GENERIC_CORE_SHA256 = "feb107342827abc813f5262829a77ddecb6ca1cc19e30cde2710dff540ce87f6"' 'fixed generic core SHA'
need "OLD_CONDITION = (" 'single reviewed condition anchor'
need "NEW_CONDITION = 'contract[\"identity\"][\"windows_task_xml_sha256_override\"] != \"\"'" 'empty override requirement'
need 'source.count(old) != 1' 'exact one-condition boundary'
need 'transformed = source.replace(old, new)' 'in-memory exact substitution'
need 'transformed.count(new) != 1' 'single new condition'
need 'os.O_NOFOLLOW' 'stable generic core open'
need 'before.st_nlink == 1' 'single-link generic core'
need 'system.posix_acl_access' 'ACL rejection'
need 'identity(before) != identity(after)' 'stable descriptor identity'
reject 'write_text|write_bytes|mkstemp|NamedTemporaryFile' 'no transformed core written to disk'
reject '/usr/bin/ssh|systemctl|systemd-run|Start-ScheduledTask|Remove-Item' 'adapter itself performs no live action'

/usr/bin/python3 -I - "$adapter" <<'PY'
import ast,difflib,hashlib,importlib.util,sys
from pathlib import Path
sys.dont_write_bytecode=True
path=Path(sys.argv[1]);spec=importlib.util.spec_from_file_location('adapter',path)
adapter=importlib.util.module_from_spec(spec);spec.loader.exec_module(adapter)
generic=Path(adapter.GENERIC_CORE).read_bytes();derived=adapter.operation_source()
assert hashlib.sha256(generic).hexdigest()==adapter.GENERIC_CORE_SHA256
old=adapter.OLD_CONDITION.encode();new=adapter.NEW_CONDITION.encode()
assert generic.count(old)==1 and new not in generic
assert derived.count(new)==1 and old not in derived
assert derived.replace(new,old)==generic
compile(generic,'generic-core','exec');compile(derived,'4fba-core','exec')
diff=list(difflib.unified_diff(generic.decode().splitlines(),derived.decode().splitlines(),n=0))
removed=[line[1:] for line in diff if line.startswith('-') and not line.startswith('---')]
added=[line[1:] for line in diff if line.startswith('+') and not line.startswith('+++')]
assert len(removed)==len(added)==1
assert adapter.OLD_CONDITION in removed[0] and adapter.NEW_CONDITION in added[0]

def comparator(source):
    tree=ast.parse(source);fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='validate_manifest')
    return [ast.dump(n,include_attributes=False) for n in ast.walk(fn) if isinstance(n,ast.Compare)
            and 'windows_task_xml_sha256_override' in ast.dump(n,include_attributes=False)]
g=comparator(generic);d=comparator(derived)
assert len(g)==len(d)==1 and g!=d
assert "Constant(value='')" in d[0]
assert 'windows_baseline' in g[0] and 'windows_baseline' not in d[0]
PY
printf '4fba early bootstrap abort core checker passed\n'
