#!/usr/bin/env bash

# Execute only the collector's exact executable PID helper against an
# impossible path. This proves a zero-match command substitution remains
# successful under the collector's set -e contract without touching services.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly COLLECTOR=$SCRIPT_DIR/../collect-viewflow-v13-bootstrap-evidence.sh

fail() {
    printf 'v1.3 bootstrap collector zero-match fixture failed: %s\n' "$*" >&2
    exit 1
}

[[ -f $COLLECTOR ]] || fail 'collector not found'
helper=$(sed -n '/^exact_executable_pids() {$/,/^}$/p' "$COLLECTOR")
[[ $helper == *$'    return 0\n}'* ]] || fail 'helper lacks explicit zero-match return'

result=$(bash -euo pipefail -c "$helper
pids=\$(exact_executable_pids /__viewflow-no-such-executable__)
[[ -z \$pids ]]") || fail 'zero-match assignment returned non-zero under set -e'
[[ -z $result ]] || fail 'zero-match helper emitted unexpected PID output'

printf 'protocol-1.3 bootstrap collector zero-match fixture passed\n'
