#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
generator=$root/deploy/linux/generate-viewflow-release-provenance.sh
checker=$root/deploy/linux/check-viewflow-release-provenance.sh
for x in "$generator" "$checker"; do [[ -x $x ]] || { echo "not executable: $x" >&2; exit 1; }; done
tmp=$(mktemp -d "${TMPDIR:-/tmp}/viewflow-release-provenance-fixture.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
src=$tmp/source; mkdir -p "$src"
cp -a -- "$root/.gitignore" "$root/Cargo.toml" "$root/Cargo.lock" "$root/LICENSE" "$root/README.md" "$root/crates" "$root/deploy" "$root/docs" "$root/platform" "$root/protocol" "$src/"
rm -rf -- "$src/deploy/__pycache__"
printf '[Service]\n' >"$tmp/viewflow-peer.service"; printf '[Service]\n' >"$tmp/viewflow.conf"
manifest=$tmp/provenance.json
build=$tmp/fresh-target
"$generator" --source-dir "$src" --build-dir "$build" --unit "$tmp/viewflow-peer.service" --dropin "$tmp/viewflow.conf" --output "$manifest" >/dev/null
sha=$(sha256sum "$manifest" | awk '{print $1}')
"$checker" --manifest "$manifest" --manifest-sha256 "$sha" >/dev/null
if "$generator" --source-dir "$src" --build-dir "$build" --unit "$tmp/viewflow-peer.service" --dropin "$tmp/viewflow.conf" --output "$manifest" >/dev/null 2>&1; then echo 'fresh target or create-once output was reused' >&2; exit 1; fi
printf '\n// mutation\n' >>"$src/crates/viewflow-platform/src/sidecar.rs"
if "$checker" --manifest "$manifest" --manifest-sha256 "$sha" >/dev/null 2>&1; then echo 'source mutation was accepted' >&2; exit 1; fi
echo 'viewflow release provenance fixture tests passed'
