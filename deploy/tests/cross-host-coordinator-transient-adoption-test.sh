#!/usr/bin/env bash
set -euo pipefail
readonly PATH=/usr/bin:/bin
export PATH

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
coordinator=${1:-$(cd -- "$script_dir/.." && pwd)/coordinated-v13-to-v2.sh}
fail() { printf 'cross-host transient adoption test failed: %s\n' "$*" >&2; exit 1; }

root=$(mktemp -d)
chmod 0700 "$root"
trap 'rm -rf -- "$root"' EXIT
sed -n '/^start_and_freeze_linux_v13() {/,/^}/p' "$coordinator" >"$root/function.sh"
grep -Fq 'process_sha=$(sha256 "/proc/$pid/exe" 2>/dev/null)' "$root/function.sh" ||
    fail 'process SHA readiness wait is absent'
# shellcheck source=/dev/null
source "$root/function.sh"

readonly expected_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
readonly gate_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
readonly exec_sha=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
readonly operation_id=11111111111111111111111111111111
readonly published_marker_sha=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
readonly old_viewflow_sha=$expected_sha
readonly FD_GATE_PAYLOAD_SHA256=$gate_sha
readonly VIEWFLOW_INSTALLED=/fixture/viewflowd
readonly v13_viewflow_unit=viewflow-v13-recovery-fixture.service
secure_dir=$root/secure
mkdir -m 0700 "$secure_dir"
linux_v13_started_receipt=$root/linux-v13-started.json
hash_attempts_file=$root/hash-attempts
printf '0\n' >"$hash_attempts_file"
start_calls=0
fixture_load_state=not-found
fixture_observed_sha=$exec_sha

die() { printf '%s\n' "$*" >&2; exit 97; }
validate_linux_v13_started() { fail 'unexpected existing-receipt validation'; }
expected_viewflow_v13_exec_start_sha() { printf '%s\n' "$exec_sha"; }
observed_transient_exec_start_sha() { printf '%s\n' "$fixture_observed_sha"; }
start_pinned_v13_transient_unit() {
    ((start_calls += 1))
    v13_viewflow_expected_exec_start_sha=$exec_sha
}
unit_main_pid() { printf '4242\n'; }
process_start_ticks() { printf '123456\n'; }
sha256() {
    local attempts
    [[ $1 == /proc/4242/exe ]] || fail "unexpected SHA target $1"
    attempts=$(<"$hash_attempts_file")
    ((attempts += 1))
    printf '%s\n' "$attempts" >"$hash_attempts_file"
    if ((attempts < 3)); then printf '%s\n' "$gate_sha"; else printf '%s\n' "$expected_sha"; fi
}
sleep() { :; }
systemctl() {
    case " $* " in
        *' --property LoadState '*) printf '%s\n' "$fixture_load_state" ;;
        *' --property InvocationID '*) printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n' ;;
        *' --property ControlGroup '*) printf '/fixture/%s\n' "$v13_viewflow_unit" ;;
        *' --property Transient '*) printf 'yes\n' ;;
        *' --property KillMode '*) printf 'control-group\n' ;;
        *) fail "unexpected systemctl invocation: $*" ;;
    esac
}
awk() {
    if [[ ${*: -1} == /proc/4242/cgroup ]]; then
        printf '/fixture/%s\n' "$v13_viewflow_unit"
    else
        /usr/bin/awk "$@"
    fi
}
journalctl() { printf 'viewflowd protocol 1.3 serving mTLS QUIC\n'; }
publish_recovery_json_once() { cp -- "$2" "$3"; }

start_and_freeze_linux_v13
[[ $start_calls == 1 && $(<"$hash_attempts_file") == 3 ]] ||
    fail 'fresh start did not wait through gate executable before accepting target'
jq -e --arg sha "$expected_sha" --arg exec "$exec_sha" '
    .state == "viewflow-linux-v1.3-started-under-deployment-quarantine" and
    .viewflowd_sha256 == $sha and .expected_exec_start_sha256 == $exec and
    .exec_start_sha256 == $exec and .main_pid == 4242
' "$linux_v13_started_receipt" >/dev/null || fail 'fresh receipt differs'

rm -- "$linux_v13_started_receipt"
fixture_load_state=loaded
printf '2\n' >"$hash_attempts_file"
start_calls=0
start_and_freeze_linux_v13
[[ $start_calls == 0 && $(<"$hash_attempts_file") == 3 ]] ||
    fail 'exact inherited transient unit was not adopted without redispatch'

rm -- "$linux_v13_started_receipt"
fixture_observed_sha=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
if (start_and_freeze_linux_v13) >/dev/null 2>&1; then
    fail 'mismatched inherited transient ExecStart was accepted'
fi

printf 'cross-host transient adoption test passed\n'
