#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH

launcher=${1:-/home/wilf/data/viewflow/deploy/launch-early-bootstrap-gate-abort-2ca3f466.sh}
die() { printf '2ca3 launcher checker: %s\n' "$*" >&2; exit 1; }
[[ -f $launcher && ! -L $launcher && $(stat -c %a -- "$launcher") == 755 ]] || die 'launcher identity/mode differs'
bash -n "$launcher" || die 'launcher does not parse'
need() { grep -F -- "$1" "$launcher" >/dev/null || die "missing contract: $2"; }
reject() { ! grep -E -- "$1" "$launcher" >/dev/null || die "forbidden construct: $2"; }

need 'readonly OP=2ca3f46635b65615a1cffc1970d73911' 'fixed operation'
need 'readonly CORE_SHA=' 'core SHA binding'
need 'readonly CORE_SHA=feb107342827abc813f5262829a77ddecb6ca1cc19e30cde2710dff540ce87f6' 'final core hash'
need 'readonly HELPER_SHA=bd562f25214cf337bd09c5b82c4ed866fdc8ac79ffb9da22ac8f5b380d659ac7' 'final helper hash'
# shellcheck disable=SC2016
need 'readonly MANIFEST=$ROOT/early-bootstrap-gate-abort-manifest.v11.json' 'immutable v11 manifest path'
need '6eeae66cd921777b7f00c037c5fea8d78230d031533f94f6023c8bd2ec99cd3f' 'exact LINUX_RECOVERED state'
need '24f8ba7e065c8a060b013eab8a5509c77ebeaf573619329f4a1d1ba8f83e64a6' 'H binding'
need 'acd3065ec439790e8f1344420a79df2667fb57abdba2f5be1b77293d723821f1' 'B binding'
need 'eebbefd9e50842f4b96aee61299e35c2a07d697b211e70b0c2c16a6b27004fe3' 'publish binding'
need '12cf89c18d9cdcdfb2f5a9222edb5e9331c3ed4d3826e25120ce7bfe20b8283e' 'request binding'
need '130a6c1cc8aef2bc0e349b4fdc233238ea193da4fabbf9370e988e8a3233be87' 'stop binding'
need 'd142fbbc65e311fa17b3307c252689afbb3963dda3e265cedc3bca7887daf96d' 'old Linux Viewflow'
need '033065b0495a2b996a6731ecf6e47c2af476e1c120ab5d62dafb8b8aa3394c3f' 'old Linux Deskflow'
need 'e2ebbfe39a1b7f5f3e30953340c000e5b249e8d957ceda5fb0e9c4efad0ffd52' 'old Linux Deskflow core'
need 'f4f29e16ccf678a75199b4af1c1ec3975434991bd54ca9688e961262466fcc26' 'old Windows Viewflow'
need '3ca9b5f498a5b80a8a54c98666e62ea84019a41fab08d2dbd8fb6f0307f47698' 'old Windows wrapper'
need '89ab8d07d19a99614361900a718e2300f6d239bf8d17b1d32101664369758b33' 'old Windows task XML'
need 'mode=check-only' 'default check-only'
need '--marker-candidate-sha256' 'external reviewed candidate SHA'
need '--reviewed-build-manifest' 'external reviewed provenance path'
need '--reviewed-build-manifest-sha256' 'external reviewed provenance SHA'
need 'readonly FINAL_MARKER_CANDIDATE=/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/viewflow-deployment-marker' 'sealed reviewed candidate path'
need 'readonly FINAL_MARKER_CANDIDATE_SHA=8d0945c582d249eb12b27f0e2eea109cc5fe20fe45358eacb3a43ff0d3880c54' 'sealed reviewed candidate hash'
need 'readonly FINAL_REVIEWED_BUILD_MANIFEST=/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/marker-reviewed-build.json' 'sealed reviewed provenance path'
need 'readonly FINAL_REVIEWED_BUILD_MANIFEST_SHA=995e2a7940de17f82ef33e48ea165a8df8ba44a641c80072d711a4b0dcaefc4d' 'sealed reviewed provenance hash'
need 'reviewed marker candidate/provenance differs from fixed binding' 'caller values are pinned to fixed bindings'
need "'reviewed_build_manifest':spec(reviewed_build_manifest,reviewed_build_manifest_sha,600)" 'manifest carries exact provenance spec'
need 'native-marker-candidate' 'native candidate identity check'
need '7f454c46' 'ELF magic check'
need 'os.O_NOFOLLOW' 'stable core open without symlink following'
need 'os.fstat(core_fd)' 'stable core FD attestation'
need '/usr/bin/python3 -I -' 'isolated Python bootstrap interpreters'
need 'os.memfd_create' 'sealed core memfd'
need 'os.MFD_ALLOW_SEALING' 'memfd sealing capability'
need 'fcntl.F_ADD_SEALS' 'core write/grow/shrink seal'
need 'fcntl.F_GET_SEALS' 'core seal readback'
need '/proc/self/fd/' 'execute the sealed core FD'
need "['/usr/bin/python3','-I',f'/proc/self/fd/{memfd}'" 'isolated sealed core exec argv'
need "{'PATH':'/usr/bin:/bin'}" 'minimal sealed core environment'
# These are literal source fragments asserted below, not shell expressions.
# shellcheck disable=SC2016
need 'if [[ $mode == execute ]]' 'explicit execute branch'
# shellcheck disable=SC2016
need 'exec /usr/bin/python3 -I - "$CORE" "$CORE_SHA" "$core_mode" "$MANIFEST" "$manifest_sha"' 'stable sealed core wrapper invocation'
# shellcheck disable=SC2016
need "core_mode=--execute" 'core execute mode binding'
need "core_mode=--check-only" 'core check-only mode binding'
need 'libc.renameat2' 'atomic no-clobber publication'
need 'RENAME_NOREPLACE' 'create-once rename flag'
need 'os.fsync(fd)' 'manifest file fsync'
need 'os.fsync(parent_fd)' 'manifest parent-directory fsync'
reject 'os\.link\(' 'link-then-unlink publication is not atomic'
reject "exec python3 \"\$CORE\"" 'core must not be reopened by path'
reject '(^|[^/])python3( |$)' 'bare Python interpreter invocation'
need "'required_absent':[runtime_marker,abort_claim,release_claim]" 'fixed external mutation sentinels only'
reject "required_absent.*outputs\.values" 'stage outputs must remain replayable'
reject '__FINAL_REVIEWED_' 'reviewed candidate/provenance bindings must be sealed'
reject '/usr/bin/ssh|systemctl|systemd-run|deskflow\.service[^\n]*(start|restart)' 'runtime actions belong only to sealed helper/core'

/usr/bin/python3 -I - "$launcher" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8')
assert s.count("<<'PY'\n")==2
blocks=s.split("<<'PY'\n")
compile(blocks[1].split('\nPY\n',1)[0],'embedded-manifest-generator','exec')
compile(blocks[2].split('\nPY\n',1)[0],'sealed-core-wrapper','exec')
assert s.index('mode=check-only') < s.index('while (($#))')
assert s.index('if [[ $mode == execute ]]') < s.index('--check-only',s.index('if [[ $mode == execute ]]'))
assert s.index("reviewed marker candidate/provenance differs from fixed binding") < s.index('exec /usr/bin/python3 -I - "$CORE"')
PY
printf '2ca3 early bootstrap gate launcher checker passed\n'
