#!/usr/bin/env bash

# Exercise only the deactivator preflight against a path-rewritten frozen
# bootstrap-v1.3 installation.  It never reaches deactivate_runtime, so no
# systemd stop/start request or marker mutation can occur.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly LINUX_DIR
readonly DEACTIVATOR=$LINUX_DIR/deactivate-viewflow-deskflow.sh

fail() { printf 'bootstrap-v1.3 legacy deactivation fixture failed: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | awk '{print tolower($1)}'; }

root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
home=$root/home/wilf
state=$home/.local/state/viewflow
output=$root/output
mkdir -p -- "$home/.local/lib/viewflow" "$home/.local/lib/deskflow-scale-fix" \
    "$home/.config/systemd/user/deskflow.service.d" "$state" "$output"
chmod 0700 -- "$state" "$output"

for executable in "$home/.local/lib/viewflow/viewflowd" \
    "$home/.local/lib/viewflow/viewflow-deployment-marker" \
    "$home/.local/lib/deskflow-scale-fix/deskflow" \
    "$home/.local/lib/deskflow-scale-fix/deskflow-core"; do
    printf 'fixture executable\n' >"$executable"
    chmod 0755 -- "$executable"
done
(umask 077; { printf 'VFDQT001'; head -c 248 /dev/zero; } >"$state/deployment-quarantine.v1")
chmod 0600 -- "$state/deployment-quarantine.v1"

unit=$home/.config/systemd/user/viewflow-peer.service
dropin=$home/.config/systemd/user/deskflow.service.d/viewflow.conf
printf '%s\n' \
    '[Unit]' \
    'Description=Viewflow authenticated QUIC peer and Deskflow input bridge' \
    '[Service]' \
    "ExecStart=$home/.local/lib/viewflow/viewflowd serve --bind 0.0.0.0:44119 --cert $home/.local/share/viewflow/identity/peer.pem --key $home/.local/share/viewflow/identity/peer.key --ca $home/.local/share/viewflow/identity/ca.pem --device-id 00000000000000000000000000000001 --sidecar-socket %t/viewflow/deskflow.sock --sidecar-peer 172.16.105.70 --sidecar-target-device 00000000000000000000000000000002" \
    'Restart=on-failure' \
    '[Install]' \
    'WantedBy=default.target' >"$unit"
printf '%s\n' \
    '[Service]' \
    "Environment=DESKFLOW_VIEWFLOW_SIDECAR_SOCKET=$root/run/user/1000/viewflow/deskflow.sock" \
    'Environment=DESKFLOW_VIEWFLOW_SCREEN=WindowsVM' \
    'Environment=DESKFLOW_VIEWFLOW_SOURCE_DISPLAY=00000000000000000000000000000101' \
    'Environment=DESKFLOW_VIEWFLOW_ROUTE_TO=00000000000000000000000000000002' >"$dropin"
chmod 0644 -- "$unit" "$dropin"

fixture=$root/deactivate-preflight-only.sh
sed \
    -e "s|/home/wilf|$home|g" \
    -e "s|/run/user/1000|$root/run/user/1000|g" \
    -e 's/^deactivate_runtime$/preflight/' \
    "$DEACTIVATOR" >"$fixture"
chmod 0700 -- "$fixture"

args=(
    --viewflow-sha256 "$(sha256 "$home/.local/lib/viewflow/viewflowd")"
    --deployment-marker-sha256 "$(sha256 "$home/.local/lib/viewflow/viewflow-deployment-marker")"
    --deskflow-sha256 "$(sha256 "$home/.local/lib/deskflow-scale-fix/deskflow")"
    --deskflow-core-sha256 "$(sha256 "$home/.local/lib/deskflow-scale-fix/deskflow-core")"
    --viewflow-unit-sha256 "$(sha256 "$unit")"
    --deskflow-dropin-sha256 "$(sha256 "$dropin")"
    --runtime-marker-state absent --bootstrap-v1.3-legacy-config
    --operation-id 0123456789abcdef0123456789abcdef
    --transcript-output "$output/transcript.txt" --proof-output "$output/proof.json"
)
HOME=$home "$fixture" "${args[@]}" >/dev/null ||
    fail 'frozen bootstrap-v1.3 preflight was rejected'
[[ ! -e $output/transcript.txt && ! -e $output/proof.json ]] ||
    fail 'preflight-only fixture wrote an output artifact'

normal_args=("${args[@]:0:14}" "${args[@]:15}")
if HOME=$home "$fixture" "${normal_args[@]}" \
    >"$root/without-legacy.out" 2>&1; then
    fail 'normal-v2 mode accepted frozen bootstrap-v1.3 configuration'
fi
grep -Fq 'both fixed quarantine markers' "$root/without-legacy.out" ||
    fail 'normal-v2 rejection did not prove the marker contract remained active'

printf 'bootstrap-v1.3 legacy deactivation preflight fixture passed\n'
