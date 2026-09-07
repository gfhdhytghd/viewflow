#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PRODUCER=${1:-$HERE/../retire-uncommitted-normal-v21-candidate.sh}
STATE=/home/wilf/.local/state/viewflow
CANDIDATES=$STATE/candidates
DEPLOYMENTS=$STATE/deployments
COORD=792da663-4417-4674-a69c-0551a8a91a71
TMP=$(mktemp -d --tmpdir viewflow-retire-hermetic.XXXXXXXX)
paths=("$TMP")
rejected_preexisting=0
[[ -d $CANDIDATES/rejected ]] && rejected_preexisting=1

cleanup() {
    local path
    for path in "${paths[@]}"; do
        [[ $path == "$STATE"/* || $path == "$TMP"/* || $path == "$TMP" ]] || continue
        rm -rf -- "$path"
    done
    if ((rejected_preexisting == 0)); then
        rmdir -- "$CANDIDATES/rejected" 2>/dev/null || true
    fi
}
trap cleanup EXIT

reject() {
    if "$@" >/dev/null 2>&1; then
        printf 'accepted unsafe retirement state: %q\n' "$1" >&2
        exit 1
    fi
}

make_case() {
    OP=$(openssl rand -hex 16)
    ROOT=$DEPLOYMENTS/$OP
    CAND=$CANDIDATES/v21-operation-$OP
    SEED=$CANDIDATES/retirement-authorized-seed-$OP
    MARKER=$STATE/.retirement-fixture-$OP.vfdqt
    mkdir -m 0700 -- "$ROOT" "$CAND" "$SEED"
    paths+=("$ROOT" "$CAND" "$SEED" "$MARKER")
    printf 'VFDQT001' >"$MARKER"
    truncate -s 256 "$MARKER"
    chmod 0600 "$MARKER"
    printf 'fixture windows executable %s\n' "$OP" >"$CAND/windows-viewflowd.exe"
    chmod 0700 "$CAND/windows-viewflowd.exe"
    printf 'fixture archive %s\n' "$OP" >"$CAND/windows-source.tar.gz"
    printf 'fixture external manifest %s\n' "$OP" >"$CAND/windows-source.manifest.sha256"
    chmod 0600 "$CAND/windows-source.tar.gz" "$CAND/windows-source.manifest.sha256"
    local exe_sha archive_sha external_sha sidecar_sha provenance_sha marker_sha publish_sha handoff_sha frozen_sha
    exe_sha=$(sha256sum "$CAND/windows-viewflowd.exe" | awk '{print $1}')
    archive_sha=$(sha256sum "$CAND/windows-source.tar.gz" | awk '{print $1}')
    external_sha=$(sha256sum "$CAND/windows-source.manifest.sha256" | awk '{print $1}')
    printf '%s  viewflow-windows-source.tar.gz\n' "$archive_sha" >"$CAND/windows-source.tar.gz.sha256"
    chmod 0600 "$CAND/windows-source.tar.gz.sha256"
    sidecar_sha=$(sha256sum "$CAND/windows-source.tar.gz.sha256" | awk '{print $1}')
    jq -cn --arg exe "$exe_sha" --argjson size "$(stat -c %s "$CAND/windows-viewflowd.exe")" \
      --arg archive "$archive_sha" --arg external "$external_sha" --arg sidecar "$sidecar_sha" \
      '{schema_version:1,kind:"viewflow-windows-native-release-provenance",protocol_version:"2.1",sidecar_protocol_version:3,
        source:{archive_checksum_sidecar_sha256:$sidecar,archive_path:"/fixture/source.tar.gz",archive_sha256:$archive,
          external_manifest_path:"/fixture/source.manifest",external_manifest_sha256:$external,manifest_entries:1,
          reviewed_readme_sha256:("a"*64)},build:{fixture:true},artifact:{remote_path:"C:\\fixture\\viewflowd.exe",sha256:$exe,size_bytes:$size}}' \
      >"$CAND/windows-native-provenance.json"
    chmod 0600 "$CAND/windows-native-provenance.json"
    provenance_sha=$(sha256sum "$CAND/windows-native-provenance.json" | awk '{print $1}')
    marker_sha=$(sha256sum "$MARKER" | awk '{print $1}')
    jq -cn --arg op "$OP" --arg coord "$COORD" --arg marker "$MARKER" --arg msha "$marker_sha" \
      '{coordinator_instance_id:$coord,created_at_unix_ms:"1",created_at_utc:"2026-09-04T12:00:00.000Z",
        marker_generation:"1",marker_path:$marker,marker_sha256:$msha,operation_id:$op,protocol_version:"2.1",
        schema_version:1,source_display_id:"00000000-0000-0000-0000-000000000101",state:"deployment-quarantine-published",
        target_device_id:"00000000-0000-0000-0000-000000000002"}' >"$ROOT/deployment-publish.json"
    chmod 0600 "$ROOT/deployment-publish.json"
    publish_sha=$(sha256sum "$ROOT/deployment-publish.json" | awk '{print $1}')
    jq -cn --arg op "$OP" --arg coord "$COORD" --arg marker "$MARKER" --arg msha "$marker_sha" \
      --arg publish "$ROOT/deployment-publish.json" --arg psha "$publish_sha" \
      '{schema_version:1,state:"viewflow-v13-marker-handoff-prepared",protocol_version:"2.1",operation_id:$op,
        source_display_id:"00000000-0000-0000-0000-000000000101",target_device_id:"00000000-0000-0000-0000-000000000002",
        coordinator_instance_id:$coord,marker_generation:"1",marker_cli_path:"/fixture/marker",marker_cli_sha256:("b"*64),
        deployment_marker_path:$marker,deployment_marker_sha256:$msha,deployment_publish_receipt_path:$publish,
        deployment_publish_receipt_sha256:$psha,deskflow_unit:"deskflow.service",deskflow_unit_active_state:"inactive",
        deskflow_unit_main_pid:0,deskflow_executable_path:"/fixture/deskflow",deskflow_executable_sha256:("c"*64),
        deskflow_exact_process_count:0,deskflow_core_executable_path:"/fixture/deskflow-core",
        deskflow_core_executable_sha256:("d"*64),deskflow_core_exact_process_count:0,deskflow_tcp_port:24800,
        deskflow_tcp_listener_count:0,runtime_marker_path:"/fixture/VFQST002",runtime_marker_present:false,
        observed_at_utc:"2026-09-04T12:00:00.000Z"}' >"$ROOT/marker-handoff.json"
    chmod 0600 "$ROOT/marker-handoff.json"
    handoff_sha=$(sha256sum "$ROOT/marker-handoff.json" | awk '{print $1}')
    jq -cn --arg op "$OP" \
      '{schema_version:1,state:"viewflow-v13-bootstrap-frozen",operation_id:$op,daemon:{},journal:{},pre_stop:{},
        post_stop:{unit_active_state:"inactive",main_pid:0,exact_process_count:0,original_daemon_pid_present:false,
          sidecar_socket_present:false,udp_44119_listener_count:0},completed_at_unix_ms:1}' >"$ROOT/linux-frozen.json"
    chmod 0600 "$ROOT/linux-frozen.json"
    frozen_sha=$(sha256sum "$ROOT/linux-frozen.json" | awk '{print $1}')
    jq -cn --arg op "$OP" --arg coord "$COORD" --arg root "$ROOT" --arg marker "$MARKER" --arg msha "$marker_sha" \
      --arg psha "$publish_sha" --arg hsha "$handoff_sha" --arg fsha "$frozen_sha" --arg cand "$CAND" \
      --arg exe "$exe_sha" --arg prov "$provenance_sha" \
      '{schema_version:1,kind:"viewflow-v21-cross-host-candidate-set",operation_id:$op,coordinator_instance_id:$coord,
        protocol_version:"2.1",sidecar_protocol_version:3,marker_generation:1,recovery_marker_generation:2,
        source_display_id:"00000000-0000-0000-0000-000000000101",target_device_id:"00000000-0000-0000-0000-000000000002",
        fresh_boundary:{root:$root,deployment_marker:$marker,deployment_marker_sha256:$msha,
          deployment_publish_receipt_sha256:$psha,marker_handoff_sha256:$hsha,linux_frozen_sha256:$fsha},
        coordinator:{},linux_rust:{},linux_deskflow:{},windows:{viewflowd:($cand+"/windows-viewflowd.exe"),viewflowd_sha256:$exe,
          wrapper:"/fixture/wrapper",wrapper_sha256:("e"*64),launcher:"/fixture/launcher",launcher_sha256:("f"*64),
          installer:"/fixture/installer",installer_sha256:("1"*64),rollback_sha256:("2"*64),
          native_provenance:($cand+"/windows-native-provenance.json"),native_provenance_sha256:$prov,
          session_1_user_sid:"S-1-5-21-fixture",old_task_xml_sha256:("3"*64),new_task_xml_override:null}}' \
      >"$CAND/candidate-manifest.json"
    chmod 0600 "$CAND/candidate-manifest.json"
    MANIFEST_SHA=$(sha256sum "$CAND/candidate-manifest.json" | awk '{print $1}')
    jq -cn '{schema_version:1,kind:"viewflow-v21-cross-host-candidate-set",protocol_version:"2.1",sidecar_protocol_version:3}' \
      >"$SEED/candidate-manifest.json"
    chmod 0600 "$SEED/candidate-manifest.json"
    SEED_SHA=$(sha256sum "$SEED/candidate-manifest.json" | awk '{print $1}')
    ARCHIVE=$CANDIDATES/rejected/v21-operation-$OP.rejected-$MANIFEST_SHA
    INTENT=$ROOT/normal-v21-candidate-retirement.intent.json
    TERMINAL=$ROOT/candidate-retirement-terminal.json
    ARGS=(--operation-id "$OP" --coordinator-instance-id "$COORD" --operation-root "$ROOT"
      --candidate-root "$CAND" --candidate-manifest-sha256 "$MANIFEST_SHA"
      --authorized-seed-root "$SEED" --authorized-seed-manifest-sha256 "$SEED_SHA")
}

finish_case() {
    paths+=("$ARCHIVE" "$ARCHIVE.swapped")
}

# Normal commit and exact replay.
make_case
before=$(stat -c '%D:%i' "$CAND")
"$PRODUCER" --check-only "${ARGS[@]}" >/dev/null
[[ ! -e $INTENT && ! -e $TERMINAL && ! -e $ARCHIVE ]]
"$PRODUCER" --execute "${ARGS[@]}" >/dev/null
finish_case
[[ ! -e $CAND && -d $ARCHIVE && $(stat -c '%D:%i' "$ARCHIVE") == "$before" ]]
terminal_sha=$(sha256sum "$TERMINAL" | awk '{print $1}')
python3 - "$TERMINAL" "$OP" "$COORD" "$ROOT" "$CAND" "$ARCHIVE" <<'PY'
import hashlib,json,os,stat,sys
p,op,coord,root,candidate,archive=sys.argv[1:]
with open(p,encoding='utf-8') as f: value=json.load(f,object_pairs_hook=dict)
assert list(value)==['schema_version','state','operation_id','coordinator_instance_id','replacement_ordinal','created_at_unix_ms','created_at_utc','operation_root','candidate_root','old_candidate','fresh_boundary','authorized_seed','pre_retirement']
assert value['state']=='viewflow-normal-v21-candidate-retired' and value['operation_id']==op and value['coordinator_instance_id']==coord
assert value['replacement_ordinal']==1 and type(value['created_at_unix_ms']) is int
assert value['operation_root']==root and value['candidate_root']==candidate
assert list(value['old_candidate'])==['canonical_path','archive_path','manifest_sha256','tree_sha256','files']
assert value['old_candidate']['archive_path']==archive
assert [f['name'] for f in value['old_candidate']['files']]==sorted(f['name'] for f in value['old_candidate']['files'])
assert all(list(f)==['name','mode','size_bytes','sha256'] for f in value['old_candidate']['files'])
assert {f['mode'] for f in value['old_candidate']['files']}=={'0600','0700'}
h=hashlib.sha256()
for record in value['old_candidate']['files']:
 path=os.path.join(archive,record['name']); st=os.stat(path,follow_symlinks=False)
 sha=hashlib.sha256(open(path,'rb').read()).hexdigest()
 assert record=={'name':record['name'],'mode':f'{stat.S_IMODE(st.st_mode):04o}','size_bytes':st.st_size,'sha256':sha}
 h.update((record['name']+'\0'+record['mode']+'\0'+str(record['size_bytes'])+'\0'+record['sha256']+'\n').encode('ascii'))
assert h.hexdigest()==value['old_candidate']['tree_sha256']
assert list(value['fresh_boundary'])==['deployment_publish_path','deployment_publish_sha256','marker_handoff_path','marker_handoff_sha256','linux_frozen_path','linux_frozen_sha256','deployment_marker_path','deployment_marker_sha256']
assert list(value['authorized_seed'])==['root','candidate_manifest_path','candidate_manifest_sha256']
assert value['pre_retirement']=={'coordinator_state_path':root+'/coordinator-state.json','coordinator_state_absent':True,'standard_normal_outputs_absent':True}
PY
intent_inode=$(stat -c '%D:%i' "$INTENT"); terminal_inode=$(stat -c '%D:%i' "$TERMINAL")
"$PRODUCER" --replay "${ARGS[@]}" >/dev/null
[[ $(sha256sum "$TERMINAL" | awk '{print $1}') == "$terminal_sha" ]]
[[ $(stat -c '%D:%i' "$INTENT") == "$intent_inode" && $(stat -c '%D:%i' "$TERMINAL") == "$terminal_inode" ]]
printf 'retirement normal/replay PASS\n'

# Build an interposer that kills only the Python transaction at the renameat2
# boundary.  This tests real durable intent and post-rename recovery without a
# production failpoint.
cat >"$TMP/kill-rename.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/types.h>
int renameat2(int a,const char*b,int c,const char*d,unsigned int e){
 static int (*real_fn)(int,const char*,int,const char*,unsigned int);
 if(!real_fn) real_fn=dlsym(RTLD_NEXT,"renameat2");
 if(getenv("RETIRE_KILL_BEFORE_RENAME")) kill(getpid(),SIGKILL);
 int rc=real_fn(a,b,c,d,e);
 if(rc==0 && getenv("RETIRE_KILL_AFTER_RENAME")) kill(getpid(),SIGKILL);
 return rc;
}
C
gcc -shared -fPIC -Wall -Wextra -Werror -o "$TMP/kill-rename.so" "$TMP/kill-rename.c" -ldl

make_case
set +e
LD_PRELOAD="$TMP/kill-rename.so" RETIRE_KILL_BEFORE_RENAME=1 "$PRODUCER" --execute "${ARGS[@]}" >/dev/null 2>&1
status=$?
set -e
((status != 0))
[[ -f $INTENT && ! -e $TERMINAL && -d $CAND && ! -e $ARCHIVE ]]
"$PRODUCER" --resume "${ARGS[@]}" >/dev/null
finish_case
[[ ! -e $CAND && -d $ARCHIVE && -f $TERMINAL ]]
printf 'retirement intent-only SIGKILL/resume PASS\n'

make_case
set +e
LD_PRELOAD="$TMP/kill-rename.so" RETIRE_KILL_AFTER_RENAME=1 "$PRODUCER" --execute "${ARGS[@]}" >/dev/null 2>&1
status=$?
set -e
((status != 0))
finish_case
[[ -f $INTENT && ! -e $TERMINAL && ! -e $CAND && -d $ARCHIVE ]]
"$PRODUCER" --resume "${ARGS[@]}" >/dev/null
[[ -f $TERMINAL ]]
printf 'retirement post-rename SIGKILL/resume PASS\n'

# No-clobber destination.
make_case
mkdir -p -m 0700 -- "$(dirname -- "$ARCHIVE")" "$ARCHIVE"
paths+=("$ARCHIVE")
reject "$PRODUCER" --check-only "${ARGS[@]}"
reject "$PRODUCER" --execute "${ARGS[@]}"
[[ -d $CAND && -d $ARCHIVE && ! -e $INTENT ]]
printf 'retirement destination no-clobber PASS\n'

# Unknown leaf and operation output both fail before intent publication.
make_case
printf unknown >"$CAND/unknown"; chmod 0600 "$CAND/unknown"
reject "$PRODUCER" --check-only "${ARGS[@]}"
rm -- "$CAND/unknown"
printf state >"$ROOT/coordinator-state.json"; chmod 0600 "$ROOT/coordinator-state.json"
reject "$PRODUCER" --execute "${ARGS[@]}"
[[ ! -e $INTENT ]]
rm -- "$ROOT/coordinator-state.json"
printf 'retirement unknown-leaf/output gate PASS\n'

# Source path symlink and ACLs are rejected.
make_case
mv -- "$CAND" "$CAND.actual"
paths+=("$CAND.actual")
ln -s -- "$CAND.actual" "$CAND"
reject "$PRODUCER" --check-only "${ARGS[@]}"
rm -- "$CAND"
mv -- "$CAND.actual" "$CAND"
if command -v setfacl >/dev/null; then
    setfacl -m u:65534:r-x -- "$CAND"
    reject "$PRODUCER" --check-only "${ARGS[@]}"
    setfacl -b -- "$CAND"
fi
printf 'retirement symlink/ACL gate PASS\n'

# A target pathname swap after the rename is detected on resume.
make_case
set +e
LD_PRELOAD="$TMP/kill-rename.so" RETIRE_KILL_AFTER_RENAME=1 "$PRODUCER" --execute "${ARGS[@]}" >/dev/null 2>&1
status=$?
set -e
((status != 0))
finish_case
mv -- "$ARCHIVE" "$ARCHIVE.swapped"
ln -s -- "$ARCHIVE.swapped" "$ARCHIVE"
reject "$PRODUCER" --resume "${ARGS[@]}"
[[ ! -e $TERMINAL ]]
printf 'retirement archive pathname-swap gate PASS\n'

printf 'uncommitted normal v2.1 candidate retirement hermetic tests passed\n'
