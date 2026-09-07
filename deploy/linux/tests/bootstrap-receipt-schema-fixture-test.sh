#!/usr/bin/env bash

# The normal installer must reject the retired one-shot bootstrap interface
# during argument processing, before uid, marker, evidence, or service checks.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly INSTALLER=$SCRIPT_DIR/../install-viewflow-deskflow.sh

fail() { printf 'legacy bootstrap rejection fixture failed: %s\n' "$*" >&2; exit 1; }

for option in \
    --bootstrap-linux-evidence \
    --bootstrap-windows-force-receipt \
    --bootstrap-windows-install-receipt \
    --windows-viewflow-sha256 \
    --windows-wrapper-sha256 \
    --windows-task-xml-sha256 \
    --windows-user-sid; do
    output=$({ "$INSTALLER" "$option" placeholder; } 2>&1 || true)
    grep -Fq 'single-stage v1.3 bootstrap is disabled' <<<"$output" ||
        fail "retired option was not rejected at parse boundary: $option"
    if grep -Eq 'systemctl|quarantine marker must|candidate is unavailable' <<<"$output"; then
        fail "retired option reached runtime preflight: $option"
    fi
done

printf 'legacy single-stage bootstrap rejection fixture passed\n'
