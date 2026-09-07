#!/usr/bin/env bash
# Bind one already-bridged normal-v2.1 operation to its candidate and launcher.
#
# This wrapper intentionally does not replace any frozen producer.  It only
# sequences their existing contracts and refuses to let a candidate/manifest
# from one operation be used by another.  The execute path remains explicit:
# it is the only path that can call a generated launcher with --execute.
set -Eeuo pipefail
export LC_ALL=C
umask 077

readonly STATE=${VIEWFLOW_PIPELINE_STATE:-/home/wilf/.local/state/viewflow}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
readonly PREPARE_DEFAULT="$HERE/prepare-normal-v21-fresh-first-candidate.sh"
readonly GENERATE_DEFAULT="$HERE/generate-normal-v21-launcher.sh"
readonly PREPARE_SHA=9a0a32b41d6909dbe823905a5c0875087b15cf673da0c11a77f0664767a78dfc
readonly GENERATE_SHA=7400882fbe16d766c08b739bf14b534e46af228fd9bc8c7936542e2cf84e7603
readonly USER_RUNTIME_DIR=/run/user/1000
readonly USER_BUS_ADDRESS=unix:path=/run/user/1000/bus

die() { printf 'error: normal-v21 operation pipeline: %s\n' "$*" >&2; exit 1; }
usage() {
    cat >&2 <<'EOF'
Usage: normal-v21-operation-pipeline.sh MODE --operation-id LOWER32 --coordinator-uuid UUID
       --fresh-root /absolute/deployments/LOWER32 --bridge-final-receipt FILE
       --bridge-final-receipt-sha256 SHA [--prepare-script FILE]
       [--generate-script FILE] [--launcher FILE] [--freshness-seconds 300]

MODE is one of:
  --prepare-generate-check  fresh-first prepare the absent per-operation candidate, generate its
                            create-once launcher, then run launcher --check-only.
  --check                  revalidate the existing candidate/launcher only.
  --execute                revalidate, enforce the publish-receipt age gate,
                            then execute.  Requires --allow-live-execute.
  --resume                 resume an already-started coordinator only. Requires
                            --allow-live-execute and its durable state.

The fresh-first arm requires the bridge final receipt plus deployment-publish,
marker-handoff, and linux-frozen leaves.  It never synthesizes a retired
candidate or a candidate-retirement terminal.
EOF
}
sha256() { sha256sum -- "$1" | awk '{print tolower($1)}'; }
regular() { [[ -f $1 && ! -L $1 && $(stat -c '%u:%h' -- "$1") == 1000:1 ]]; }
pin_script() {
    local label=$1 path=$2 expected=$3 mode=$4
    [[ $path == /* && $expected =~ ^[0-9a-f]{64}$ ]] || die "invalid $label pin"
    regular "$path" && [[ $(stat -c '%a' -- "$path") == "$mode" ]] || die "unsafe $label"
    [[ $(sha256 "$path") == "$expected" ]] || die "$label SHA differs from its frozen contract"
}
assert_user_bus() {
    [[ $(id -u) == 1000 ]] || die 'live execution requires uid 1000'
    [[ -d $USER_RUNTIME_DIR && ! -L $USER_RUNTIME_DIR &&
       $(stat -c '%u:%a' -- "$USER_RUNTIME_DIR") == 1000:700 ]] ||
        die 'live execution requires the real owner-only /run/user/1000 runtime directory'
    [[ -S $USER_RUNTIME_DIR/bus && ! -L $USER_RUNTIME_DIR/bus &&
       $(stat -c '%u' -- "$USER_RUNTIME_DIR/bus") == 1000 ]] ||
        die 'live execution requires the uid-1000 D-Bus socket'
    export XDG_RUNTIME_DIR=$USER_RUNTIME_DIR
    export DBUS_SESSION_BUS_ADDRESS=$USER_BUS_ADDRESS
}

mode=''; op=''; coord=''; root=''; bridge=''; bridge_sha=''; prepare=$PREPARE_DEFAULT; generate=$GENERATE_DEFAULT; launcher=''
allow_execute=0 freshness_seconds=300
while (($#)); do
    case $1 in
        --prepare-generate-check|--check|--execute|--resume) [[ -z $mode ]] || die 'choose exactly one mode'; mode=$1; shift ;;
        --allow-live-execute) allow_execute=1; shift ;;
        --operation-id) op=${2-}; shift 2 ;;
        --coordinator-uuid) coord=${2-}; shift 2 ;;
        --fresh-root) root=${2-}; shift 2 ;;
        --bridge-final-receipt) bridge=${2-}; shift 2 ;;
        --bridge-final-receipt-sha256) bridge_sha=${2-}; shift 2 ;;
        --prepare-script) prepare=${2-}; shift 2 ;;
        --generate-script) generate=${2-}; shift 2 ;;
        --launcher) launcher=${2-}; shift 2 ;;
        --freshness-seconds) freshness_seconds=${2-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
done
[[ $mode && $op =~ ^[0-9a-f]{32}$ && $coord =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die 'canonical mode, operation ID, and coordinator UUID are required'
[[ $root == "$STATE/deployments/$op" && $bridge == "$root/v4-inactive-terminal-to-fresh-v21.json" && $bridge_sha =~ ^[0-9a-f]{64}$ && $freshness_seconds =~ ^[1-9][0-9]*$ && $freshness_seconds -le 300 ]] || die 'root/bridge must be canonical and freshness must be 1..300 seconds'
[[ -z $launcher ]] && launcher="$root/launch-normal-v21.sh"
[[ $launcher == "$root/launch-normal-v21.sh" ]] || die 'launcher must be the canonical operation leaf'
[[ $mode != --execute && $mode != --resume || $allow_execute == 1 ]] || die '--execute/--resume requires --allow-live-execute'

# The production producers are frozen.  Tests may supply an explicitly pinned
# replacement through PIPELINE_PREPARE_SHA / PIPELINE_GENERATE_SHA; the hashes
# remain mandatory, so the wrapper never silently executes a substituted tool.
prepare_sha=${PIPELINE_PREPARE_SHA:-$PREPARE_SHA}
generate_sha=${PIPELINE_GENERATE_SHA:-$GENERATE_SHA}
pin_script 'prepare script' "$prepare" "$prepare_sha" 755
pin_script 'generator script' "$generate" "$generate_sha" 644

# Strictly bind all bridge leaves to the requested operation before invoking a
# producer.  A second pass after preparation verifies the new candidate
# manifest's root/OP/coordinator closure and returns only pinned digests.
validate() {
    local candidate_required=$1
    python3 - "$STATE" "$op" "$coord" "$root" "$bridge" "$bridge_sha" "$launcher" "$candidate_required" "$freshness_seconds" <<'PY'
import hashlib, json, os, re, stat, sys, time
state,op,coord,root,bridge_path,bridge_expected,launcher,need_candidate,max_age=sys.argv[1:]
def die(s): raise SystemExit('error: operation-pipeline validation: '+s)
def load(path,mode=0o600):
    try: fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    except OSError as e: die('open '+path+': '+str(e))
    try:
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or stat.S_IMODE(st.st_mode)!=mode or st.st_nlink!=1: die('unsafe '+path)
        data=b''
        while True:
            part=os.read(fd,131072)
            if not part: break
            data+=part
    finally: os.close(fd)
    def pairs(items):
        out={}
        for k,v in items:
            if k in out: raise ValueError('duplicate key')
            out[k]=v
        return out
    try:
        text=data.decode('utf-8','strict'); d,end=json.JSONDecoder(object_pairs_hook=pairs,parse_float=lambda _: (_ for _ in ()).throw(ValueError('float')),parse_constant=lambda _: (_ for _ in ()).throw(ValueError('constant'))).raw_decode(text)
    except Exception as e: die('invalid JSON '+path+': '+str(e))
    if text[end:].strip() or type(d) is not dict: die('non-canonical JSON '+path)
    return d,hashlib.sha256(data).hexdigest()
def hashed(path,mode):
    try: fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    except OSError as e: die('open '+path+': '+str(e))
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid!=os.getuid() or stat.S_IMODE(before.st_mode)!=mode or before.st_nlink!=1: die('unsafe '+path)
        h=hashlib.sha256(); size=0
        while True:
            part=os.read(fd,131072)
            if not part: break
            h.update(part); size+=len(part)
        after=os.fstat(fd)
    finally: os.close(fd)
    try: named=os.lstat(path)
    except OSError as e: die('re-stat '+path+': '+str(e))
    fields=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_uid,stat.S_IMODE(s.st_mode),s.st_nlink)
    if not (fields(before)==fields(after)==fields(named)): die('changed '+path)
    return h.hexdigest(),size
def must(d, **want):
    for k,v in want.items():
        if d.get(k)!=v: die('binding '+k+' differs')
if os.path.realpath(root)!=root or not os.path.isdir(root) or os.path.islink(root): die('unsafe operation root')
rst=os.stat(root)
if rst.st_uid!=os.getuid() or stat.S_IMODE(rst.st_mode)!=0o700: die('operation root identity')
paths={n:root+'/'+n for n in ('deployment-publish.json','marker-handoff.json','linux-frozen.json')}
p,psha=load(paths['deployment-publish.json']); h,hsha=load(paths['marker-handoff.json']); f,fsha=load(paths['linux-frozen.json']); b,bsha=load(bridge_path)
must(p, schema_version=1,state='deployment-quarantine-published',operation_id=op,coordinator_instance_id=coord,protocol_version='2.1',marker_generation='1')
must(h, schema_version=1,state='viewflow-v13-marker-handoff-prepared',operation_id=op,coordinator_instance_id=coord,protocol_version='2.1',marker_generation='1')
must(f, schema_version=1,state='viewflow-v13-bootstrap-frozen',operation_id=op)
if type(f.get('completed_at_unix_ms')) is not int or not 0 < f['completed_at_unix_ms'] <= 9007199254740991: die('frozen completion timestamp')
if bsha!=bridge_expected: die('bridge final SHA')
if list(b)!=['schema_version','state','old_operation_id','new_operation_id','new_coordinator_instance_id','marker_generation','inactive_source','persistent_v13','fresh_boundary']: die('bridge final schema')
must(b, schema_version=1,state='viewflow-v4-inactive-terminal-to-fresh-v21',new_operation_id=op,new_coordinator_instance_id=coord,marker_generation='1')
if not isinstance(b.get('old_operation_id'),str) or not re.fullmatch(r'[0-9a-f]{32}',b['old_operation_id']) or b['old_operation_id']==op: die('bridge old operation identity')
inactive=b.get('inactive_source'); persistent=b.get('persistent_v13')
if not isinstance(inactive,dict) or list(inactive)!=['source_validation_sha256','terminal_sha256','authorization_sha256','abort_receipt_sha256','abort_query_receipt_sha256','vfdqa_sha256','linux_initially_inactive','windows_old_peer_unchanged'] or not all(isinstance(inactive.get(k),str) and re.fullmatch(r'[0-9a-f]{64}',inactive[k]) for k in list(inactive)[:6]) or inactive.get('linux_initially_inactive') is not True or inactive.get('windows_old_peer_unchanged') is not True: die('bridge inactive-source closure')
if not isinstance(persistent,dict) or list(persistent)!=['persistent_started_sha256','authenticated_probe_record_sha256','stopped_by_collector'] or not all(isinstance(persistent.get(k),str) and re.fullmatch(r'[0-9a-f]{64}',persistent[k]) for k in list(persistent)[:2]) or persistent.get('stopped_by_collector') is not True: die('bridge persistent-v13 closure')
if h.get('deployment_publish_receipt_path')!=paths['deployment-publish.json'] or h.get('deployment_publish_receipt_sha256')!=psha: die('handoff/publish closure')
expected={'deployment_publish_sha256':psha,'marker_handoff_sha256':hsha,'linux_frozen_sha256':fsha,'deployment_marker_sha256':p.get('marker_sha256'),'protocol_version':'2.1'}
if b.get('fresh_boundary')!=expected: die('bridge fresh-boundary closure')
cand=state+'/candidates/v21-operation-'+op
if need_candidate=='1':
    try: cst=os.lstat(cand)
    except OSError as e: die('candidate root: '+str(e))
    if not stat.S_ISDIR(cst.st_mode) or stat.S_ISLNK(cst.st_mode) or cst.st_uid!=os.getuid() or stat.S_IMODE(cst.st_mode)!=0o700 or os.path.realpath(cand)!=cand: die('candidate root identity')
    m,msha=load(cand+'/candidate-manifest.json')
    if m.get('schema_version')!=1 or m.get('operation_id')!=op or m.get('coordinator_instance_id')!=coord or 'candidate_replacement' in m: die('candidate operation binding')
    fb=m.get('fresh_boundary',{})
    if fb.get('root')!=root or fb.get('deployment_publish_receipt_sha256')!=psha or fb.get('marker_handoff_sha256')!=hsha or fb.get('linux_frozen_sha256')!=fsha: die('candidate fresh-boundary closure')
    artifacts={'windows-viewflowd.exe':('87631e877811377f018d65dc5ca2b1d6b68e2b268d7d15b8d0646aac3d9f5b04',0o700),'windows-native-provenance.json':('fc4cb5cff71ad859f113cd2ad21cfff90217401772cba08f21c0394735bac17d',0o600),'windows-source.manifest.sha256':('7ecccb607a166c847aa1293905f8fd14909803734751b6ca71549470fc6f95e2',0o600),'windows-source.tar.gz':('da3014217499fc7deb5eac1fa07fb85e9cbfcecb0bff9fd14df54530d3367131',0o600),'windows-source.tar.gz.sha256':('aea8ec8fe6232e0883b97e58cd027e735b1e2a39b2c3761b5a3fcadbff7139ee',0o600)}
    if set(os.listdir(cand))!=set(artifacts)|{'candidate-manifest.json'}: die('candidate exact six leaves')
    rows=[]
    for name,(digest,mode) in sorted(artifacts.items()):
        actual,size=hashed(cand+'/'+name,mode)
        if actual!=digest: die('candidate artifact SHA '+name)
        rows.append(name+'\0'+format(mode,'04o')+'\0'+str(size)+'\0'+actual+'\n')
    manifest_digest,manifest_size=hashed(cand+'/candidate-manifest.json',0o600)
    if manifest_digest!=msha: die('candidate manifest changed')
    rows.append('candidate-manifest.json\0'+'0600\0'+str(manifest_size)+'\0'+manifest_digest+'\n')
    tree=hashlib.sha256(''.join(sorted(rows)).encode('ascii')).hexdigest()
    c,csha=load(root+'/first-candidate-commit.json')
    commit_keys=['schema_version','state','operation_id','coordinator_instance_id','operation_root','candidate_root','candidate_manifest_path','candidate_manifest_sha256','candidate_tree_sha256','bridge_final_path','bridge_final_sha256','fresh_boundary']
    if list(c)!=commit_keys or c.get('schema_version')!=1 or c.get('state')!='viewflow-normal-v21-first-candidate-committed' or c.get('operation_id')!=op or c.get('coordinator_instance_id')!=coord or c.get('operation_root')!=root or c.get('candidate_root')!=cand or c.get('candidate_manifest_path')!=cand+'/candidate-manifest.json' or c.get('candidate_manifest_sha256')!=msha or not isinstance(c.get('candidate_tree_sha256'),str) or not re.fullmatch(r'[0-9a-f]{64}',c['candidate_tree_sha256']) or c['candidate_tree_sha256']!=tree or c.get('bridge_final_path')!=bridge_path or c.get('bridge_final_sha256')!=bridge_expected or c.get('fresh_boundary')!=expected: die('first-candidate commit closure')
    lst=os.lstat(launcher)
    if not (stat.S_ISREG(lst.st_mode) and not stat.S_ISLNK(lst.st_mode) and lst.st_uid==os.getuid() and lst.st_nlink==1 and stat.S_IMODE(lst.st_mode)==0o500): die('unsafe launcher')
    fd=os.open(launcher,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        lh=hashlib.sha256()
        while True:
            part=os.read(fd,131072)
            if not part: break
            lh.update(part)
        lsha=lh.hexdigest()
    finally: os.close(fd)
else: msha=lsha=''
if not isinstance(p.get('created_at_unix_ms'),str) or not re.fullmatch(r'[1-9][0-9]*',p['created_at_unix_ms']): die('publish timestamp')
now_ms=time.time_ns()//1_000_000
age_ms=now_ms-int(p['created_at_unix_ms'])
age=age_ms//1000
if age_ms < -30000 or age_ms > int(max_age)*1000: age_state='stale'
else: age_state='fresh'
frozen_age_ms=now_ms-f['completed_at_unix_ms']
frozen_age=frozen_age_ms//1000
if frozen_age_ms < -30000 or frozen_age_ms > int(max_age)*1000: frozen_state='stale'
else: frozen_state='fresh'
print('\t'.join((psha,hsha,fsha,bsha,msha,lsha,str(age),age_state,str(frozen_age),frozen_state)))
PY
}

pre_values=$(validate 0)
IFS=$'\t' read -r publish_sha handoff_sha frozen_sha bridge_actual_sha _ <<<"$pre_values"
candidate="$STATE/candidates/v21-operation-$op"
coordinator_state="$root/coordinator-state.json"
if [[ $mode == --execute && ( -e $coordinator_state || -L $coordinator_state ) ]]; then
    die 'coordinator state exists; use --resume --allow-live-execute'
fi
if [[ $mode == --resume ]]; then
    [[ -f $coordinator_state && ! -L $coordinator_state && $(stat -c '%a:%u:%h' -- "$coordinator_state") == 600:1000:1 ]] || die '--resume requires an owner-only coordinator-state.json'
fi
if [[ $mode == --prepare-generate-check ]]; then
    [[ ! -e $launcher && ! -L $launcher ]] || die 'create-once launcher already exists; use --check'
    prepare_resume=()
    [[ -e $candidate || -L $candidate ]] && prepare_resume+=(--resume)
    bash "$prepare" --operation-id "$op" --coordinator-uuid "$coord" --fresh-root "$root" \
        --handoff "$root/marker-handoff.json" --frozen "$root/linux-frozen.json" --publish "$root/deployment-publish.json" \
        --bridge-final-receipt "$bridge" --bridge-final-receipt-sha256 "$bridge_sha" "${prepare_resume[@]}"
    manifest_sha=$(sha256 "$candidate/candidate-manifest.json")
    bash "$generate" --operation-id "$op" --coordinator-uuid "$coord" --candidate-manifest-sha256 "$manifest_sha" \
        --fresh-root "$root" --handoff "$root/marker-handoff.json" --frozen "$root/linux-frozen.json" \
        --publish "$root/deployment-publish.json" --output "$launcher"
fi
values=$(validate 1)
IFS=$'\t' read -r publish_sha handoff_sha frozen_sha bridge_actual_sha manifest_sha launcher_sha marker_age marker_state frozen_age frozen_state <<<"$values"
if [[ $mode == --execute ]]; then
    [[ $marker_state == fresh ]] || die "publish marker is ${marker_age}s old; bridge a new operation instead of extending freshness"
    [[ $frozen_state == fresh ]] || die "Linux frozen evidence is ${frozen_age}s old; bridge a new operation instead of extending freshness"
fi
if [[ $mode == --resume ]]; then
    # The generated launcher validates its durable state before invoking the
    # coordinator.  Do not run --check-only here: that mode correctly rejects
    # a committed coordinator state as a non-fresh initial launch.
    assert_user_bus
    exec "$launcher" --resume
fi
bash "$launcher" --check-only
printf 'operation=%s candidate=%s manifest_sha256=%s launcher_sha256=%s publish_sha256=%s handoff_sha256=%s frozen_sha256=%s bridge_final_sha256=%s marker_age_seconds=%s\n' \
    "$op" "$candidate" "$manifest_sha" "$launcher_sha" "$publish_sha" "$handoff_sha" "$frozen_sha" "$bridge_actual_sha" "$marker_age"
if [[ $mode == --execute ]]; then
    values=$(validate 1)
    IFS=$'\t' read -r publish_sha handoff_sha frozen_sha bridge_actual_sha manifest_sha launcher_sha marker_age marker_state frozen_age frozen_state <<<"$values"
    [[ $marker_state == fresh ]] || die "publish marker is ${marker_age}s old; bridge a new operation instead of extending freshness"
    [[ $frozen_state == fresh ]] || die "Linux frozen evidence is ${frozen_age}s old; bridge a new operation instead of extending freshness"
    assert_user_bus
    exec "$launcher" --execute
fi
