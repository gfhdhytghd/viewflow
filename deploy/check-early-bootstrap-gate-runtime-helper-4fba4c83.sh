#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
export PYTHONDONTWRITEBYTECODE=1

adapter=${1:-/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper-4fba4c83.py}
die() { printf '4fba helper checker: %s\n' "$*" >&2; exit 1; }
[[ -f $adapter && ! -L $adapter && $(stat -c %a -- "$adapter") == 755 ]] || die 'adapter identity/mode differs'
need() { grep -F -- "$1" "$adapter" >/dev/null || die "missing contract: $2"; }
reject() { ! grep -E -- "$1" "$adapter" >/dev/null || die "forbidden construct: $2"; }

need 'GENERIC_HELPER = "/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper.py"' 'fixed generic helper path'
need 'GENERIC_HELPER_SHA256 = "bd562f25214cf337bd09c5b82c4ed866fdc8ac79ffb9da22ac8f5b380d659ac7"' 'fixed generic helper SHA'
need 'OLD_OPERATION_ID = "2ca3f46635b65615a1cffc1970d73911"' 'reviewed source operation'
need 'OPERATION_ID = "4fba4c832389436ba980efaa4540f6bf"' 'operation-specific identity'
need 'EXPECTED_OPERATION_OCCURRENCES = 2' 'exact substitution cardinality'
need 'os.O_NOFOLLOW' 'no-follow generic helper open'
need 'before.st_nlink == 1' 'single-link generic helper'
need 'system.posix_acl_access' 'ACL rejection'
need 'identity(before) != identity(after)' 'stable descriptor identity'
need 'hashlib.sha256(data).hexdigest() != GENERIC_HELPER_SHA256' 'generic helper hash check'
need 'source.count(old) != EXPECTED_OPERATION_OCCURRENCES' 'exact replacement boundary'
need 'transformed = source.replace(old, new)' 'in-memory operation substitution'
need 'code = compile(source' 'compile transformed bytes in memory'
reject 'write_text|write_bytes|mkstemp|NamedTemporaryFile' 'no transformed helper written to disk'
reject '/usr/bin/ssh|systemctl|systemd-run|Start-ScheduledTask|Remove-Item' 'adapter itself performs no live action'

/usr/bin/python3 -I - "$adapter" <<'PY'
import importlib.util,sys,types
from pathlib import Path
sys.dont_write_bytecode=True
path=Path(sys.argv[1]);spec=importlib.util.spec_from_file_location('adapter',path)
adapter=importlib.util.module_from_spec(spec);spec.loader.exec_module(adapter)
source=adapter.operation_source()
assert source.count(adapter.OPERATION_ID.encode())==adapter.EXPECTED_OPERATION_OCCURRENCES
assert adapter.OLD_OPERATION_ID.encode() not in source
module=types.ModuleType('operation_helper')
module.__file__=str(path)+'#transformed'
exec(compile(source,module.__file__,'exec'),module.__dict__)
assert module.OPERATION_ID=='4fba4c832389436ba980efaa4540f6bf'
assert module.WINDOWS_ROOT.endswith('\\4fba4c832389436ba980efaa4540f6bf')
assert "$op='4fba4c832389436ba980efaa4540f6bf'" in module.powershell_census_script()
assert 'Viewflow Deployment ' + module.OPERATION_ID == 'Viewflow Deployment 4fba4c832389436ba980efaa4540f6bf'
assert module.WINDOWS_PID==22912 and module.WINDOWS_PARENT_PID==25608
assert module.WINDOWS_FILETIME=='134326073277429320'
assert module.WINDOWS_HOST=='wilf@172.16.105.70'
assert 'Start-ScheduledTask' not in source.decode()
PY
printf '4fba early bootstrap runtime helper checker passed\n'
