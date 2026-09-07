#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
source_script=${1:-/home/wilf/data/viewflow/deploy/reconcile-post-vfdqa-replay6-operation55.sh}
checker=${POST_VFDQA_CHECKER:-/home/wilf/data/viewflow/deploy/check-post-vfdqa-replay6-operation55.sh}
tmp=$(mktemp /tmp/viewflow-post-vfdqa-negative.XXXXXX)
trap 'rm -f -- "$tmp"' EXIT
mutate_fail(){ local from=$1 to=$2; sed "s|$from|$to|" "$source_script" >"$tmp"; ! cmp -s "$source_script" "$tmp" || { echo "mutation did not hit: $from" >&2; exit 1; }; ! "$checker" "$tmp" >/dev/null 2>&1 || { echo "mutation escaped: $from" >&2; exit 1; }; }
mutate_fail 'AUTHZ_PROVENANCE_INVALID' 'AUTHZ_PROVENANCE_VALID'
mutate_fail 'fresh_bridge_ready:false' 'fresh_bridge_ready:true'
mutate_fail 'normal_success_terminal:false' 'normal_success_terminal:true'
mutate_fail 'old_authorization_retroactively_validated:false' 'old_authorization_retroactively_validated:true'
mutate_fail 'exit 1};exit 0' 'exit 0};exit 0'
mutate_fail 'os.link(src,dst,follow_symlinks=False)' 'open(dst,"wb").write(data)'
mutate_fail 'os.unlink(src); source_removed=True; os.fsync(dfd)' 'os.unlink(src); os.fsync(dfd)'
mutate_fail 'if created and not source_removed:' 'if created:'
mutate_fail 'peer.st_nlink==2 and' 'peer.st_nlink==9 and'
mutate_fail 'validate_live_runtime; capture_live_runtime' ':; capture_live_runtime'
printf 'post-VFDQA replay6 static-negative mutations passed\n'
