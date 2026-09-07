#!/usr/bin/env bash
# Offline, create-once normal-v2.1 launcher generator.
set -Eeuo pipefail
export LC_ALL=C
umask 077

readonly STATE_ROOT=/home/wilf/.local/state/viewflow
readonly RUST="$STATE_ROOT/candidates/linux-rust-release-cleanenv-v3-20260904T123027Z-oZ1vdq"
readonly DESK="$STATE_ROOT/candidates/v21-deskflow-pristine-20260904-sAVGIrEN"
readonly DESK_BUILD="$DESK/source/build-ninja-release"
readonly SRC="$RUST/source-stage"
readonly COORDINATOR="$SRC/deploy/coordinated-v13-to-v2.sh"
readonly REVIEWED_MARKER="$RUST/release-target/release/viewflow-deployment-marker"
readonly REVIEWED_BUILD="$RUST/viewflow-linux-rust-release-provenance.json"
readonly REVIEWED_MARKER_SHA=e3c981f57a775d343c9e62a7d604a3d4aa3e79f3014e64c9ed8c9e6bbf1581f5
readonly REVIEWED_BUILD_SHA=53c1155422f141af639058d767a42eebcc76e59a7aa71951b913b0ddaf22ee47

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { printf '%s\n' "Usage: $0 --operation-id HEX32 --coordinator-uuid UUID --candidate-manifest-sha256 LOWER64 --fresh-root DIR --handoff FILE --frozen FILE --publish FILE --output FILE" >&2; }
sha256() { sha256sum -- "$1" | awk '{print tolower($1)}'; }
owner_only_dir() { [[ -d $1 && ! -L $1 && $(stat -c '%a:%u' -- "$1") == 700:1000 ]]; }
regular_input() { [[ -f $1 && ! -L $1 ]]; }
check_file() {
    local path=$1 expected=$2 before after
    regular_input "$path" || die "unsafe or missing candidate: $path"
    before=$(stat -c '%d:%i:%s:%u:%a:%h' -- "$path")
    [[ $(sha256 "$path") == "$expected" ]] || die "candidate hash mismatch: $path"
    after=$(stat -c '%d:%i:%s:%u:%a:%h' -- "$path")
    [[ $before == "$after" ]] || die "candidate changed while being hashed: $path"
}

# Read all JSON inputs through an O_NOFOLLOW descriptor and reject every
# non-canonical JSON form before accepting any fresh-boundary evidence.  This
# function deliberately prints only the digests which the generated launcher
# must pin and re-check immediately before either check-only or execute.
bundle_validator() {
    python3 - "$@" <<'PY'
import calendar,hashlib,json,os,re,stat,sys,time

OP,COORD,ROOT,CAND,MANIFEST_EXPECTED,HANDOFF,FROZEN,PUBLISH=sys.argv[1:]
HEX=re.compile(r"[0-9a-f]{64}\Z")
UUID=re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
OP_RE=re.compile(r"[0-9a-f]{32}\Z")
UTC=re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\Z")
MARKER_CLI="/home/wilf/.local/lib/viewflow/viewflow-deployment-marker"
RUNTIME_MARKER="/home/wilf/.local/state/viewflow/deskflow-quarantine.v2"
SOURCE="00000000-0000-0000-0000-000000000101"
TARGET="00000000-0000-0000-0000-000000000002"
REVIEWED_MARKER="/home/wilf/.local/state/viewflow/candidates/linux-rust-release-cleanenv-v3-20260904T123027Z-oZ1vdq/release-target/release/viewflow-deployment-marker"
REVIEWED_MARKER_SHA="e3c981f57a775d343c9e62a7d604a3d4aa3e79f3014e64c9ed8c9e6bbf1581f5"
COORDINATOR="/home/wilf/.local/state/viewflow/candidates/linux-rust-release-cleanenv-v3-20260904T123027Z-oZ1vdq/source-stage/deploy/coordinated-v13-to-v2.sh"
COORDINATOR_SHA="986f4ce5d86cb9e049328705fecc1be27e26c348176e4ff5b41235e675ae4970"

def die(msg): raise SystemExit("error: fresh-boundary validation: "+msg)
def req(ok,msg):
    if not ok: die(msg)
def pairs(pairs):
    out={}
    for k,v in pairs:
        if k in out: die("duplicate JSON key "+repr(k))
        out[k]=v
    return out
def bad_number(token): die("floating/non-finite JSON number "+token)
def secure(path,mode):
    try: fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    except OSError as e: die("cannot O_NOFOLLOW open "+path+": "+str(e))
    try:
        before=os.fstat(fd)
        req(stat.S_ISREG(before.st_mode),"not regular "+path)
        req(before.st_uid==1000 and stat.S_IMODE(before.st_mode)==mode and before.st_nlink==1,
            "identity mismatch "+path)
        data=bytearray()
        while True:
            chunk=os.read(fd,131072)
            if not chunk: break
            data.extend(chunk)
        after=os.fstat(fd)
    finally: os.close(fd)
    req((before.st_dev,before.st_ino,before.st_size,before.st_uid,stat.S_IMODE(before.st_mode),before.st_nlink)==
        (after.st_dev,after.st_ino,after.st_size,after.st_uid,stat.S_IMODE(after.st_mode),after.st_nlink),
        "descriptor changed while read "+path)
    try: named=os.lstat(path)
    except OSError as e: die("cannot re-stat "+path+": "+str(e))
    req(not stat.S_ISLNK(named.st_mode) and
        (named.st_dev,named.st_ino,named.st_size,named.st_uid,stat.S_IMODE(named.st_mode),named.st_nlink)==
        (after.st_dev,after.st_ino,after.st_size,after.st_uid,stat.S_IMODE(after.st_mode),after.st_nlink),
        "path changed while read "+path)
    return bytes(data),hashlib.sha256(data).hexdigest()
def load(path,mode=0o600):
    data,digest=secure(path,mode)
    try:
        text=data.decode("utf-8")
        decoder=json.JSONDecoder(object_pairs_hook=pairs,parse_float=bad_number,parse_constant=bad_number)
        obj,end=decoder.raw_decode(text)
    except (UnicodeDecodeError,json.JSONDecodeError) as e: die("invalid JSON "+path+": "+str(e))
    req(text[end:].strip()=="","trailing JSON data "+path)
    return obj,digest
def keys(obj,want,label): req(type(obj) is dict and set(obj)==set(want),label+" schema")
def string(v,label): req(type(v) is str,label+" must be string")
def sha(v,label): string(v,label); req(bool(HEX.fullmatch(v)),label+" must be lowercase sha256")
def uuid(v,label): string(v,label); req(bool(UUID.fullmatch(v)),label+" must be lowercase UUID")
def op(v,label): string(v,label); req(bool(OP_RE.fullmatch(v)),label+" must be lower hex32")
def boolean(v,label): req(type(v) is bool,label+" must be boolean")
def integer(v,label): req(type(v) is int and not isinstance(v,bool),label+" must be integer")
def path(v,label): string(v,label); req(v.startswith("/"),label+" must be absolute")
def ordered_keys(obj,want,label): req(type(obj) is dict and list(obj)==list(want),label+" keys must be exact and ordered")
def timestamp(obj,label):
    integer(obj["created_at_unix_ms"],label+" unix timestamp")
    req(obj["created_at_unix_ms"]>0,label+" unix timestamp must be nonzero")
    string(obj["created_at_utc"],label+" UTC")
    req(bool(UTC.fullmatch(obj["created_at_utc"])),label+" UTC must be canonical")
    text=obj["created_at_utc"]; whole,fraction=text[:-1].split(".")
    parsed=calendar.timegm(time.strptime(whole,"%Y-%m-%dT%H:%M:%S"))*1000+int(fraction)
    req(parsed==obj["created_at_unix_ms"],label+" timestamp mismatch")
def secure_dir(path_value,label):
    path(path_value,label)
    try: st=os.lstat(path_value)
    except OSError as e: die("cannot stat "+label+": "+str(e))
    # Directory link counts are filesystem-specific (Btrfs reports one), so
    # only require a live directory link. Regular candidate files remain
    # pinned to exactly one link below.
    req(stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode) and st.st_uid==1000 and stat.S_IMODE(st.st_mode)==0o700 and st.st_nlink>=1,label+" identity mismatch")
def tree_records(root,label):
    secure_dir(root,label)
    expected_names={"candidate-manifest.json","windows-native-provenance.json","windows-source.manifest.sha256","windows-source.tar.gz","windows-source.tar.gz.sha256","windows-viewflowd.exe"}
    entries=sorted(os.listdir(root))
    req(not any(os.path.isdir(os.path.join(root,name)) and not os.path.islink(os.path.join(root,name)) for name in entries),label+" must not contain subdirectories")
    req(set(entries)==expected_names,"%s must contain exactly the six candidate artifacts" % label)
    records=[]
    for base,dirs,files in os.walk(root,topdown=True,followlinks=False):
        dirs.sort(); files.sort()
        for name in files:
            full=os.path.join(base,name); rel=os.path.relpath(full,root).replace(os.sep,"/")
            st=os.lstat(full)
            req(stat.S_ISREG(st.st_mode) and not stat.S_ISLNK(st.st_mode) and st.st_uid==1000 and st.st_nlink==1,label+" contains unsafe file "+rel)
            expected_mode=0o700 if name=="windows-viewflowd.exe" else 0o600
            req(stat.S_IMODE(st.st_mode)==expected_mode,label+" mode mismatch "+rel)
            data,digest=secure(full,stat.S_IMODE(st.st_mode))
            records.append({"name":rel,"mode":format(stat.S_IMODE(st.st_mode),"04o"),"size_bytes":len(data),"sha256":digest})
        for name in dirs:
            full=os.path.join(base,name); st=os.lstat(full)
            req(stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode) and st.st_uid==1000 and stat.S_IMODE(st.st_mode)==0o700 and st.st_nlink>=1,label+" contains unsafe directory "+os.path.relpath(full,root))
    records.sort(key=lambda x:x["name"])
    tree=b"".join((r["name"]+"\0"+r["mode"]+"\0"+str(r["size_bytes"])+"\0"+r["sha256"]+"\n").encode() for r in records)
    return records,hashlib.sha256(tree).hexdigest()
def load_replacement_artifact(path_value,expected,label):
    path(path_value,label+" path")
    obj,digest=load(path_value)
    req(expected is None or digest==expected,label+" SHA mismatch")
    return obj,digest

m,msha=load(CAND+"/candidate-manifest.json")
req(msha==MANIFEST_EXPECTED,"candidate manifest SHA mismatch")
manifest_keys=["schema_version","kind","operation_id","coordinator_instance_id","protocol_version","sidecar_protocol_version","marker_generation","recovery_marker_generation","source_display_id","target_device_id","fresh_boundary","candidate_replacement","coordinator","linux_rust","linux_deskflow","windows"]
manifest_v1_keys=[x for x in manifest_keys if x!="candidate_replacement"]
req(type(m) is dict and list(m) in (manifest_v1_keys,manifest_keys),"candidate manifest schema")
replacement_schema=(m["schema_version"]==2 and list(m)==manifest_keys)
req((m["schema_version"]==1 and list(m)==manifest_v1_keys) or replacement_schema,"candidate protocol schema")
req(m["kind"]=="viewflow-v21-cross-host-candidate-set" and m["protocol_version"]=="2.1" and m["sidecar_protocol_version"]==3,"candidate protocol schema")
req(m["operation_id"]==OP and m["coordinator_instance_id"]==COORD and m["marker_generation"]==1 and m["recovery_marker_generation"]==2,"candidate operation binding")
req(m["source_display_id"]==SOURCE and m["target_device_id"]==TARGET,"candidate device binding")
keys(m["fresh_boundary"],{"root","deployment_marker","deployment_marker_sha256","deployment_publish_receipt_sha256","marker_handoff_sha256","linux_frozen_sha256"},"candidate fresh boundary")
fb=m["fresh_boundary"]; req(fb["root"]==ROOT,"candidate fresh root binding"); path(fb["deployment_marker"],"candidate marker path"); sha(fb["deployment_marker_sha256"],"candidate marker sha"); sha(fb["deployment_publish_receipt_sha256"],"candidate publish sha"); sha(fb["marker_handoff_sha256"],"candidate handoff sha"); sha(fb["linux_frozen_sha256"],"candidate frozen sha")
keys(m["coordinator"],{"entrypoint","entrypoint_sha256","source_provenance","source_provenance_sha256"},"candidate coordinator")
req(m["coordinator"]["entrypoint"]==COORDINATOR and m["coordinator"]["entrypoint_sha256"]==COORDINATOR_SHA,"candidate coordinator pin")
keys(m["linux_rust"],{"viewflowd","viewflowd_sha256","deployment_marker","deployment_marker_sha256","reviewed_build_manifest","reviewed_build_manifest_sha256","provenance","provenance_sha256","unit","unit_sha256","deskflow_dropin","deskflow_dropin_sha256"},"candidate linux rust")
req(m["linux_rust"]["deployment_marker"]==REVIEWED_MARKER and m["linux_rust"]["deployment_marker_sha256"]==REVIEWED_MARKER_SHA,"candidate reviewed marker pin")
keys(m["linux_deskflow"],{"deskflow","deskflow_sha256","deskflow_core","deskflow_core_sha256","provenance","provenance_sha256"},"candidate deskflow")
keys(m["windows"],{"viewflowd","viewflowd_sha256","wrapper","wrapper_sha256","launcher","launcher_sha256","installer","installer_sha256","rollback_sha256","native_provenance","native_provenance_sha256","session_1_user_sid","old_task_xml_sha256","new_task_xml_override"},"candidate windows")
req(m["windows"]["viewflowd"]==CAND+"/windows-viewflowd.exe" and m["windows"]["native_provenance"]==CAND+"/windows-native-provenance.json","candidate Windows path binding")
for label,val in (("candidate viewflow sha",m["windows"]["viewflowd_sha256"]),("candidate native provenance sha",m["windows"]["native_provenance_sha256"]),("candidate old task sha",m["windows"]["old_task_xml_sha256"])): sha(val,label)
req(m["windows"]["new_task_xml_override"] is None,"candidate new task XML override")

p,psha=load(PUBLISH)
keys(p,{"schema_version","state","protocol_version","operation_id","coordinator_instance_id","marker_generation","source_display_id","target_device_id","marker_path","marker_sha256","created_at_unix_ms","created_at_utc"},"publish receipt")
req(p["schema_version"]==1 and p["state"]=="deployment-quarantine-published" and p["protocol_version"]=="2.1" and p["operation_id"]==OP and p["coordinator_instance_id"]==COORD and p["marker_generation"]=="1" and p["source_display_id"]==SOURCE and p["target_device_id"]==TARGET,"publish binding")
path(p["marker_path"],"publish marker path"); sha(p["marker_sha256"],"publish marker sha"); string(p["created_at_unix_ms"],"publish timestamp"); req(p["created_at_unix_ms"].isdigit(),"publish timestamp canonical"); string(p["created_at_utc"],"publish UTC"); req(bool(UTC.fullmatch(p["created_at_utc"])),"publish UTC canonical")

h,hsha=load(HANDOFF)
keys(h,{"schema_version","state","protocol_version","operation_id","coordinator_instance_id","marker_generation","source_display_id","target_device_id","deployment_marker_path","deployment_marker_sha256","deployment_publish_receipt_path","deployment_publish_receipt_sha256","marker_cli_path","marker_cli_sha256","runtime_marker_path","runtime_marker_present","deskflow_unit","deskflow_unit_active_state","deskflow_unit_main_pid","deskflow_tcp_port","deskflow_tcp_listener_count","deskflow_executable_path","deskflow_executable_sha256","deskflow_exact_process_count","deskflow_core_executable_path","deskflow_core_executable_sha256","deskflow_core_exact_process_count","observed_at_utc"},"handoff receipt")
req(h["schema_version"]==1 and h["state"]=="viewflow-v13-marker-handoff-prepared" and h["protocol_version"]=="2.1" and h["operation_id"]==OP and h["coordinator_instance_id"]==COORD and h["marker_generation"]=="1" and h["source_display_id"]==SOURCE and h["target_device_id"]==TARGET,"handoff binding")
req(h["deployment_marker_path"]==p["marker_path"] and h["deployment_marker_sha256"]==p["marker_sha256"] and h["deployment_publish_receipt_path"]==PUBLISH and h["deployment_publish_receipt_sha256"]==psha,"handoff publish/marker closure")
req(h["marker_cli_path"]==MARKER_CLI and h["marker_cli_sha256"]==REVIEWED_MARKER_SHA and h["runtime_marker_path"]==RUNTIME_MARKER and h["runtime_marker_present"] is False,"handoff marker CLI binding")
req(h["deskflow_unit"]=="deskflow.service" and h["deskflow_unit_active_state"]=="inactive" and h["deskflow_unit_main_pid"]==0 and h["deskflow_tcp_port"]==24800 and h["deskflow_tcp_listener_count"]==0 and h["deskflow_exact_process_count"]==0 and h["deskflow_core_exact_process_count"]==0,"handoff Deskflow quiescence")
for label,val in (("handoff deskflow executable",h["deskflow_executable_path"]),("handoff core executable",h["deskflow_core_executable_path"])): path(val,label)
for label,val in (("handoff deskflow sha",h["deskflow_executable_sha256"]),("handoff core sha",h["deskflow_core_executable_sha256"])): sha(val,label)
string(h["observed_at_utc"],"handoff UTC"); req(bool(UTC.fullmatch(h["observed_at_utc"])),"handoff UTC canonical")

f,fsha=load(FROZEN)
keys(f,{"schema_version","state","operation_id","daemon","journal","pre_stop","post_stop","completed_at_unix_ms"},"frozen evidence")
req(f["schema_version"]==1 and f["state"]=="viewflow-v13-bootstrap-frozen" and f["operation_id"]==OP,"frozen binding"); integer(f["completed_at_unix_ms"],"frozen completion")
keys(f["daemon"],{"boot_id","daemon_instance_id","executable","pid","sha256","start_ticks","systemd_invocation_id"},"frozen daemon")
keys(f["journal"],{"counts","end_cursor","end_realtime_timestamp_us","entry_count","protocol_startup_cursor","protocol_startup_realtime_timestamp_us","query_boot_id","query_pid","query_systemd_invocation_id","slice_sha256","start_cursor","start_realtime_timestamp_us"},"frozen journal")
keys(f["journal"]["counts"],{"cleanup_or_release_error","input_event","input_sidecar_activation","lease_offered","protocol_1_3_startup"},"frozen journal counts")
keys(f["pre_stop"],{"deskflow_core_exact_process_count","deskflow_exact_process_count","deskflow_main_pid","deskflow_tcp_24800_listener_count","deskflow_unit_active_state"},"frozen pre-stop")
keys(f["post_stop"],{"command_output_format","command_output_sha256","command_outputs","exact_process_count","main_pid","original_daemon_pid_present","sidecar_socket_present","udp_44119_listener_count","unit_active_state"},"frozen post-stop")
keys(f["post_stop"]["command_outputs"],{"exact_viewflow_pids","original_daemon_pid_present","sidecar_socket_present","systemctl_is_active","systemctl_main_pid","udp_44119_listeners"},"frozen command outputs")
req(f["pre_stop"]["deskflow_unit_active_state"]=="inactive" and f["pre_stop"]["deskflow_main_pid"]==0 and f["pre_stop"]["deskflow_exact_process_count"]==0 and f["pre_stop"]["deskflow_core_exact_process_count"]==0 and f["pre_stop"]["deskflow_tcp_24800_listener_count"]==0,"frozen pre-stop quiescence")
req(f["post_stop"]["unit_active_state"]=="inactive" and f["post_stop"]["main_pid"]==0 and f["post_stop"]["exact_process_count"]==0 and f["post_stop"]["original_daemon_pid_present"] is False and f["post_stop"]["sidecar_socket_present"] is False and f["post_stop"]["udp_44119_listener_count"]==0,"frozen post-stop quiescence")

req(fb["deployment_marker"]==p["marker_path"] and fb["deployment_marker_sha256"]==p["marker_sha256"] and fb["deployment_publish_receipt_sha256"]==psha and fb["marker_handoff_sha256"]==hsha and fb["linux_frozen_sha256"]==fsha,"candidate P/H/F closure")
_,marker_sha=secure(p["marker_path"],0o600)
req(marker_sha==p["marker_sha256"],"marker file hash closure")
term_sha=commit_sha=term_path=commit_path=""
if replacement_schema:
    cr=m["candidate_replacement"]
    ordered_keys(cr,["retirement_terminal_path","retirement_terminal_sha256","old_candidate_manifest_sha256","replacement_ordinal","authorized_seed_manifest_sha256"],"candidate replacement")
    path(cr["retirement_terminal_path"],"candidate retirement terminal")
    sha(cr["retirement_terminal_sha256"],"candidate retirement terminal SHA")
    sha(cr["old_candidate_manifest_sha256"],"candidate old manifest SHA")
    integer(cr["replacement_ordinal"],"candidate replacement ordinal"); req(cr["replacement_ordinal"]>0,"candidate replacement ordinal must be positive")
    sha(cr["authorized_seed_manifest_sha256"],"candidate authorized seed SHA")
    term_path=cr["retirement_terminal_path"]; term_sha=cr["retirement_terminal_sha256"]
    req(term_path==os.path.join(ROOT,"candidate-retirement-terminal.json"),"candidate retirement terminal path is not the fresh-root terminal")
    commit_path=os.path.join(ROOT,"candidate-replacement-commit.json")
    term,term_digest=load_replacement_artifact(term_path,term_sha,"retirement terminal")
    ordered_keys(term,["schema_version","state","operation_id","coordinator_instance_id","replacement_ordinal","created_at_unix_ms","created_at_utc","operation_root","candidate_root","old_candidate","fresh_boundary","authorized_seed","pre_retirement"],"retirement terminal")
    req(term["schema_version"]==1 and term["state"]=="viewflow-normal-v21-candidate-retired" and term["operation_id"]==OP and term["coordinator_instance_id"]==COORD,"retirement terminal binding")
    req(term["replacement_ordinal"]==cr["replacement_ordinal"] and term["operation_root"]==ROOT and term["candidate_root"]==CAND,"retirement terminal root binding")
    timestamp(term,"retirement terminal")
    ordered_keys(term["old_candidate"],["canonical_path","archive_path","manifest_sha256","tree_sha256","files"],"retired candidate")
    old=term["old_candidate"]; path(old["canonical_path"],"retired candidate canonical path"); path(old["archive_path"],"retired candidate archive path"); sha(old["manifest_sha256"],"retired candidate manifest SHA"); sha(old["tree_sha256"],"retired candidate tree SHA")
    req(old["manifest_sha256"]==cr["old_candidate_manifest_sha256"],"retired candidate manifest closure"); req(old["manifest_sha256"]!=cr["authorized_seed_manifest_sha256"],"retired candidate must differ from authorized seed"); req(old["canonical_path"]==CAND,"retired candidate canonical path binding")
    records,tree_sha=tree_records(old["archive_path"],"retired candidate archive")
    req(tree_sha==old["tree_sha256"],"retired candidate tree SHA mismatch")
    req(old["files"]==records,"retired candidate file inventory mismatch")
    archived_manifest=os.path.join(old["archive_path"],"candidate-manifest.json")
    _,archived_manifest_sha=secure(archived_manifest,0o600)
    req(archived_manifest_sha==old["manifest_sha256"],"retired candidate manifest file mismatch")
    ordered_keys(term["fresh_boundary"],["deployment_publish_path","deployment_publish_sha256","marker_handoff_path","marker_handoff_sha256","linux_frozen_path","linux_frozen_sha256","deployment_marker_path","deployment_marker_sha256"],"retirement terminal fresh boundary")
    tf=term["fresh_boundary"]
    req(tf=={"deployment_publish_path":PUBLISH,"deployment_publish_sha256":psha,"marker_handoff_path":HANDOFF,"marker_handoff_sha256":hsha,"linux_frozen_path":FROZEN,"linux_frozen_sha256":fsha,"deployment_marker_path":p["marker_path"],"deployment_marker_sha256":p["marker_sha256"]},"retirement terminal P/H/F/marker closure")
    ordered_keys(term["authorized_seed"],["root","candidate_manifest_path","candidate_manifest_sha256"],"authorized seed")
    seed=term["authorized_seed"]; path(seed["root"],"authorized seed root"); path(seed["candidate_manifest_path"],"authorized seed manifest path"); sha(seed["candidate_manifest_sha256"],"authorized seed manifest SHA")
    req(seed["candidate_manifest_path"].startswith(seed["root"].rstrip("/")+"/"),"authorized seed manifest root binding")
    _,seed_sha=secure(seed["candidate_manifest_path"],0o600); req(seed_sha==seed["candidate_manifest_sha256"]==cr["authorized_seed_manifest_sha256"],"authorized seed manifest closure")
    ordered_keys(term["pre_retirement"],["coordinator_state_path","coordinator_state_absent","standard_normal_outputs_absent"],"retirement pre-state")
    pre=term["pre_retirement"]; path(pre["coordinator_state_path"],"retirement coordinator state path"); req(pre["coordinator_state_path"]==os.path.join(ROOT,"coordinator-state.json") and pre["coordinator_state_absent"] is True and pre["standard_normal_outputs_absent"] is True,"retirement pre-state closure")
    req(not os.path.lexists(pre["coordinator_state_path"]),"retirement coordinator state must be absent")
    commit,commit_digest=load_replacement_artifact(commit_path,None,"candidate replacement commit")
    commit_sha=commit_digest
    ordered_keys(commit,["schema_version","state","operation_id","coordinator_instance_id","replacement_ordinal","created_at_unix_ms","created_at_utc","operation_root","candidate_root","candidate_manifest_path","candidate_manifest_sha256","candidate_tree_sha256","retirement_terminal_path","retirement_terminal_sha256","old_candidate_archive_path","old_candidate_manifest_sha256","authorized_seed_manifest_sha256","fresh_boundary"],"candidate replacement commit")
    req(commit["schema_version"]==1 and commit["state"]=="viewflow-normal-v21-candidate-replacement-committed" and commit["operation_id"]==OP and commit["coordinator_instance_id"]==COORD and commit["replacement_ordinal"]==cr["replacement_ordinal"] and commit["operation_root"]==ROOT and commit["candidate_root"]==CAND,"candidate replacement commit binding")
    timestamp(commit,"candidate replacement commit")
    req(commit["candidate_manifest_path"]==CAND+"/candidate-manifest.json" and commit["candidate_manifest_sha256"]==msha and commit["retirement_terminal_path"]==term_path and commit["retirement_terminal_sha256"]==term_sha and commit["old_candidate_archive_path"]==old["archive_path"] and commit["old_candidate_manifest_sha256"]==old["manifest_sha256"] and commit["authorized_seed_manifest_sha256"]==cr["authorized_seed_manifest_sha256"],"candidate replacement commit closure")
    sha(commit["candidate_tree_sha256"],"candidate tree SHA"); _,candidate_tree_sha=tree_records(CAND,"candidate replacement tree"); req(commit["candidate_tree_sha256"]==candidate_tree_sha,"candidate replacement tree SHA mismatch"); ordered_keys(commit["fresh_boundary"],list(tf),"replacement commit fresh boundary"); req(commit["fresh_boundary"]==tf,"replacement commit P/H/F/marker closure")
print(msha,marker_sha,hsha,fsha,psha,term_sha,commit_sha,term_path,commit_path)
PY
}

# Resume is permitted only from a durable coordinator state bound to this exact
# operation.  Use an O_NOFOLLOW descriptor so a path swap cannot turn a
# missing/foreign state into a resume authorization.
resume_state_validator() {
    python3 - "$@" <<'PY'
import json,os,stat,sys
path,op=sys.argv[1:]
def die(msg): raise SystemExit("error: resume state validation: "+msg)
def pairs(items):
 out={}
 for k,v in items:
  if k in out: die("duplicate JSON key "+repr(k))
  out[k]=v
 return out
def bad(token): die("floating/non-finite JSON number "+token)
try: fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
except OSError as e: die("cannot O_NOFOLLOW open state: "+str(e))
try:
 before=os.fstat(fd)
 if not stat.S_ISREG(before.st_mode): die("state is not regular")
 data=bytearray()
 while True:
  chunk=os.read(fd,131072)
  if not chunk: break
  data.extend(chunk)
 after=os.fstat(fd)
finally: os.close(fd)
if (before.st_dev,before.st_ino,before.st_size,before.st_uid,before.st_nlink)!=(after.st_dev,after.st_ino,after.st_size,after.st_uid,after.st_nlink): die("state changed while read")
named=os.lstat(path)
if stat.S_ISLNK(named.st_mode) or (named.st_dev,named.st_ino,named.st_size,named.st_uid,named.st_nlink)!=(after.st_dev,after.st_ino,after.st_size,after.st_uid,after.st_nlink): die("state path changed while read")
try:
 text=bytes(data).decode("utf-8"); dec=json.JSONDecoder(object_pairs_hook=pairs,parse_float=bad,parse_constant=bad); obj,end=dec.raw_decode(text)
except (UnicodeDecodeError,json.JSONDecodeError) as e: die("invalid state JSON: "+str(e))
if text[end:].strip(): die("trailing state JSON data")
if type(obj) is not dict or obj.get("operation_id")!=op: die("state operation binding")
PY
}

operation_id=''
coordinator_uuid=''
candidate_manifest_sha256=''
fresh_root=''
handoff=''
frozen=''
publish=''
output=''
while (($#)); do
    case $1 in
        --operation-id) operation_id=${2-}; shift 2 ;;
        --coordinator-uuid) coordinator_uuid=${2-}; shift 2 ;;
        --candidate-manifest-sha256) candidate_manifest_sha256=${2-}; shift 2 ;;
        --fresh-root) fresh_root=${2-}; shift 2 ;;
        --handoff) handoff=${2-}; shift 2 ;;
        --frozen) frozen=${2-}; shift 2 ;;
        --publish) publish=${2-}; shift 2 ;;
        --output) output=${2-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
done
[[ $operation_id =~ ^[0-9a-f]{32}$ ]] || die '--operation-id must be exactly 32 lowercase hexadecimal characters'
[[ $coordinator_uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die '--coordinator-uuid must be a lowercase UUID'
[[ $candidate_manifest_sha256 =~ ^[0-9a-f]{64}$ ]] || die '--candidate-manifest-sha256 must be exactly 64 lowercase hexadecimal characters'
for path in "$fresh_root" "$handoff" "$frozen" "$publish" "$output"; do
    [[ $path == /* ]] || die 'all paths must be absolute'
done
owner_only_dir "$fresh_root" || die 'fresh root must be an owner-only 0700 directory with one link'
for path in "$handoff" "$frozen" "$publish"; do regular_input "$path" || die "unsafe or missing fresh input: $path"; done
[[ ! -e $output && ! -L $output ]] || die 'output already exists'
output_parent=$(dirname -- "$output")
owner_only_dir "$output_parent" || die 'output parent must be an owner-only 0700 directory with one link'

# All candidate/provenance checks finish before irreversible output creation.
readonly CAND="$STATE_ROOT/candidates/v21-operation-$operation_id"
owner_only_dir "$CAND" || die 'operation candidate root must be owner-only 0700'
[[ $(stat -c '%a:%u:%h' -- "$CAND/candidate-manifest.json") == 600:1000:1 ]] ||
    die 'candidate manifest identity must be owner-only 0600 with one link'
check_file "$CAND/candidate-manifest.json" "$candidate_manifest_sha256"
check_file "$COORDINATOR" 986f4ce5d86cb9e049328705fecc1be27e26c348176e4ff5b41235e675ae4970
check_file "$RUST/viewflow-linux-rust-release-provenance.json" 53c1155422f141af639058d767a42eebcc76e59a7aa71951b913b0ddaf22ee47
check_file "$RUST/release-target/release/viewflowd" 0ed2dcf3c56565b9ce55349cf36f6cc0aba3dc8ff741fc864caf5c865ddba667
check_file "$REVIEWED_MARKER" "$REVIEWED_MARKER_SHA"
check_file "$REVIEWED_BUILD" "$REVIEWED_BUILD_SHA"
check_file "$RUST/source-stage/deploy/linux/viewflow-peer.service" 9b36f2e998ddade3746c0ca18fbe9633cfa39afde5b5de3d2887975a794b4315
check_file "$RUST/source-stage/deploy/linux/deskflow-viewflow.conf" 6af3e6d4a7156c58e21515c17227e804a4787e132e7310449cc267a1562a141d
check_file "$DESK/deskflow-provenance.json" 103d9d7561163f5c70ad42629c7ec8f8ae38ca307e475467d8e27bab12a03946
check_file "$DESK_BUILD/bin/deskflow" a14e44fb29656bc9e7107b6910b52c3650822751ecef5389ad98b58c740559c0
check_file "$DESK_BUILD/bin/deskflow-core" 8dea6bd05c740177c80b6879929cdc058e3a2713772657318a0ea46c8620dad5
check_file "$CAND/windows-viewflowd.exe" 87631e877811377f018d65dc5ca2b1d6b68e2b268d7d15b8d0646aac3d9f5b04
check_file "$CAND/windows-native-provenance.json" fc4cb5cff71ad859f113cd2ad21cfff90217401772cba08f21c0394735bac17d
check_file "$CAND/windows-source.manifest.sha256" 7ecccb607a166c847aa1293905f8fd14909803734751b6ca71549470fc6f95e2
check_file "$CAND/windows-source.tar.gz" da3014217499fc7deb5eac1fa07fb85e9cbfcecb0bff9fd14df54530d3367131
check_file "$CAND/windows-source.tar.gz.sha256" aea8ec8fe6232e0883b97e58cd027e735b1e2a39b2c3761b5a3fcadbff7139ee
check_file "$SRC/deploy/windows/viewflow-client.ps1" 2791c959914eb9bf5662577e52773a9bbb6d83a8015625fb938969715f74781a
check_file "$SRC/deploy/windows/start-viewflow-bootstrap.ps1" 5880e945533d36c99200d6b0663ff9ffcdc465cdcff80d7b8ee6c59950ea4904
check_file "$SRC/deploy/windows/install-viewflow.ps1" c73b7047fba9d23ae1bd195ba51c2ad48a5a4c3b8c47764b17170cbdf32da75e
check_file "$SRC/deploy/windows/rollback-viewflow.ps1" f57a3a997eb69f9d99f8d4d0bc0c5f4766f6fc8c26835e0476340356ef0930eb
env -i HOME=/home/wilf PATH=/usr/bin:/bin bash "$SRC/deploy/linux/check-viewflow-release-provenance.sh" --manifest "$RUST/viewflow-linux-rust-release-provenance.json" --manifest-sha256 53c1155422f141af639058d767a42eebcc76e59a7aa71951b913b0ddaf22ee47
bash "$SRC/deploy/linux/check-deskflow-provenance.sh" --manifest "$DESK/deskflow-provenance.json" --manifest-sha256 103d9d7561163f5c70ad42629c7ec8f8ae38ca307e475467d8e27bab12a03946 --deskflow-candidate "$DESK_BUILD/bin/deskflow" --deskflow-sha256 a14e44fb29656bc9e7107b6910b52c3650822751ecef5389ad98b58c740559c0 --deskflow-core-candidate "$DESK_BUILD/bin/deskflow-core" --deskflow-core-sha256 8dea6bd05c740177c80b6879929cdc058e3a2713772657318a0ea46c8620dad5
bundle_values=$(bundle_validator "$operation_id" "$coordinator_uuid" "$fresh_root" "$CAND" "$candidate_manifest_sha256" "$handoff" "$frozen" "$publish")
read -r manifest_sha marker_sha handoff_sha frozen_sha publish_sha replacement_terminal_sha replacement_commit_sha replacement_terminal_path replacement_commit_path <<<"$bundle_values"
[[ $manifest_sha == "$candidate_manifest_sha256" && $marker_sha =~ ^[0-9a-f]{64}$ && $handoff_sha =~ ^[0-9a-f]{64}$ && $frozen_sha =~ ^[0-9a-f]{64}$ && $publish_sha =~ ^[0-9a-f]{64}$ ]] || die 'fresh-boundary validator returned invalid digest set'
if [[ -n $replacement_terminal_sha ]]; then
    [[ $replacement_terminal_sha =~ ^[0-9a-f]{64}$ && $replacement_commit_sha =~ ^[0-9a-f]{64}$ && $replacement_terminal_path == /* && $replacement_commit_path == /* ]] || die 'replacement validator returned invalid artifact set'
fi

# O_EXCL/noclobber create-once: never rename over or replace an output.
set -C
exec 3>"$output"
printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'export LC_ALL=C' >&3
printf 'readonly OP=%q\nreadonly COORD=%q\nreadonly CANDIDATE_MANIFEST_SHA=%q\nreadonly MARKER_SHA=%q\nreadonly HANDOFF_SHA=%q\nreadonly FROZEN_SHA=%q\nreadonly PUBLISH_SHA=%q\nreadonly REPLACEMENT_TERMINAL_SHA=%q\nreadonly REPLACEMENT_COMMIT_SHA=%q\nreadonly REPLACEMENT_TERMINAL=%q\nreadonly REPLACEMENT_COMMIT=%q\nreadonly ROOT=%q\nreadonly HANDOFF=%q\nreadonly FROZEN=%q\nreadonly PUBLISH=%q\n' "$operation_id" "$coordinator_uuid" "$candidate_manifest_sha256" "$marker_sha" "$handoff_sha" "$frozen_sha" "$publish_sha" "$replacement_terminal_sha" "$replacement_commit_sha" "$replacement_terminal_path" "$replacement_commit_path" "$fresh_root" "$handoff" "$frozen" "$publish" >&3
declare -f bundle_validator >&3
declare -f resume_state_validator >&3
cat >&3 <<'LAUNCHER'
readonly CAND="/home/wilf/.local/state/viewflow/candidates/v21-operation-$OP"
readonly RUST=/home/wilf/.local/state/viewflow/candidates/linux-rust-release-cleanenv-v3-20260904T123027Z-oZ1vdq
readonly DESK=/home/wilf/.local/state/viewflow/candidates/v21-deskflow-pristine-20260904-sAVGIrEN
readonly DESK_BUILD="$DESK/source/build-ninja-release"
readonly SRC="$RUST/source-stage"
readonly COORDINATOR="$SRC/deploy/coordinated-v13-to-v2.sh"
readonly REVIEWED_MARKER="$RUST/release-target/release/viewflow-deployment-marker"
readonly REVIEWED_MARKER_SHA=e3c981f57a775d343c9e62a7d604a3d4aa3e79f3014e64c9ed8c9e6bbf1581f5
readonly REVIEWED_BUILD="$RUST/viewflow-linux-rust-release-provenance.json"
readonly REVIEWED_BUILD_SHA=53c1155422f141af639058d767a42eebcc76e59a7aa71951b913b0ddaf22ee47
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
regular_input() { [[ -f $1 && ! -L $1 ]]; }
sha256() { sha256sum -- "$1" | awk '{print tolower($1)}'; }
check_file() {
    local path=$1 expected=$2 before after
    regular_input "$path" || die "unsafe or missing candidate: $path"
    before=$(stat -c '%d:%i:%s:%u:%a:%h' -- "$path")
    [[ $(sha256 "$path") == "$expected" ]] || die "candidate hash mismatch: $path"
    after=$(stat -c '%d:%i:%s:%u:%a:%h' -- "$path")
    [[ $before == "$after" ]] || die "candidate changed while being hashed: $path"
}
[[ ${BASH_SOURCE[0]} == "$0" ]] || die 'launcher must be executed, not sourced'
[[ $# -le 1 ]] || die 'usage: launch-normal-v21.sh [--check-only|--execute|--resume]'
mode=${1:---check-only}
[[ $mode == --check-only || $mode == --execute || $mode == --resume ]] || die 'usage: launch-normal-v21.sh [--check-only|--execute|--resume]'
[[ $(id -u) == 1000 && ${HOME-} == /home/wilf ]] || die 'must run as uid 1000 with HOME=/home/wilf'
[[ -d $ROOT && ! -L $ROOT && $(stat -c '%a:%u' -- "$ROOT") == 700:1000 ]] || die 'fresh root identity mismatch'
outputs=(recovery-deployment-publish.json recovery-deployment-publish.json.intent.json deployment-release.json cpp-status-response.json cpp-arm-response.json cpp-cleanup-receipt.json rust-acceptance-arm-response.json rust-acceptance-query-response.json post-release-receipt.json windows-restart-receipt.json linux-host-proof.json windows-bootstrap-request.json windows-prepared.json windows-mutation-permit.json windows-force-envelope.json linux-stage.json linux-stage.json.backup linux-stage.json.backup/consume-intent.json linux-finalize.json windows-install.json windows-installer-exit.json coordinator-state.json coordinator-state.json.recovery-bundle.json coordinator-state.json.windows-stop-evidence.json coordinator-state.json.windows-restart-intent.json coordinator-state.json.pre-mutation-retry.json coordinator-state.json.pre-mutation-start-intent.v1.json coordinator-state.json.pre-mutation-stop-claim.v1 linux-deactivation-transcript.json linux-deactivation.json linux-containment.transcript windows-validation.json windows-rollback.json)
if [[ $mode == --resume ]]; then
    resume_state_validator "$ROOT/coordinator-state.json" "$OP"
else
    for leaf in "${outputs[@]}"; do [[ ! -e $ROOT/$leaf && ! -L $ROOT/$leaf ]] || die "fresh output already exists: $ROOT/$leaf"; done
fi
[[ $(stat -c '%a:%u:%h' -- "$CAND/candidate-manifest.json") == 600:1000:1 ]] ||
    die 'candidate manifest identity must be owner-only 0600 with one link'
check_file "$CAND/candidate-manifest.json" "$CANDIDATE_MANIFEST_SHA"
check_file "$COORDINATOR" 986f4ce5d86cb9e049328705fecc1be27e26c348176e4ff5b41235e675ae4970
check_file "$RUST/viewflow-linux-rust-release-provenance.json" 53c1155422f141af639058d767a42eebcc76e59a7aa71951b913b0ddaf22ee47
check_file "$RUST/release-target/release/viewflowd" 0ed2dcf3c56565b9ce55349cf36f6cc0aba3dc8ff741fc864caf5c865ddba667
check_file "$REVIEWED_MARKER" "$REVIEWED_MARKER_SHA"
check_file "$REVIEWED_BUILD" "$REVIEWED_BUILD_SHA"
check_file "$RUST/source-stage/deploy/linux/viewflow-peer.service" 9b36f2e998ddade3746c0ca18fbe9633cfa39afde5b5de3d2887975a794b4315
check_file "$RUST/source-stage/deploy/linux/deskflow-viewflow.conf" 6af3e6d4a7156c58e21515c17227e804a4787e132e7310449cc267a1562a141d
check_file "$DESK/deskflow-provenance.json" 103d9d7561163f5c70ad42629c7ec8f8ae38ca307e475467d8e27bab12a03946
check_file "$DESK_BUILD/bin/deskflow" a14e44fb29656bc9e7107b6910b52c3650822751ecef5389ad98b58c740559c0
check_file "$DESK_BUILD/bin/deskflow-core" 8dea6bd05c740177c80b6879929cdc058e3a2713772657318a0ea46c8620dad5
check_file "$CAND/windows-viewflowd.exe" 87631e877811377f018d65dc5ca2b1d6b68e2b268d7d15b8d0646aac3d9f5b04
check_file "$CAND/windows-native-provenance.json" fc4cb5cff71ad859f113cd2ad21cfff90217401772cba08f21c0394735bac17d
check_file "$CAND/windows-source.manifest.sha256" 7ecccb607a166c847aa1293905f8fd14909803734751b6ca71549470fc6f95e2
check_file "$CAND/windows-source.tar.gz" da3014217499fc7deb5eac1fa07fb85e9cbfcecb0bff9fd14df54530d3367131
check_file "$CAND/windows-source.tar.gz.sha256" aea8ec8fe6232e0883b97e58cd027e735b1e2a39b2c3761b5a3fcadbff7139ee
check_file "$SRC/deploy/windows/viewflow-client.ps1" 2791c959914eb9bf5662577e52773a9bbb6d83a8015625fb938969715f74781a
check_file "$SRC/deploy/windows/start-viewflow-bootstrap.ps1" 5880e945533d36c99200d6b0663ff9ffcdc465cdcff80d7b8ee6c59950ea4904
check_file "$SRC/deploy/windows/install-viewflow.ps1" c73b7047fba9d23ae1bd195ba51c2ad48a5a4c3b8c47764b17170cbdf32da75e
check_file "$SRC/deploy/windows/rollback-viewflow.ps1" f57a3a997eb69f9d99f8d4d0bc0c5f4766f6fc8c26835e0476340356ef0930eb
env -i HOME=/home/wilf PATH=/usr/bin:/bin bash "$SRC/deploy/linux/check-viewflow-release-provenance.sh" --manifest "$RUST/viewflow-linux-rust-release-provenance.json" --manifest-sha256 53c1155422f141af639058d767a42eebcc76e59a7aa71951b913b0ddaf22ee47
bash "$SRC/deploy/linux/check-deskflow-provenance.sh" --manifest "$DESK/deskflow-provenance.json" --manifest-sha256 103d9d7561163f5c70ad42629c7ec8f8ae38ca307e475467d8e27bab12a03946 --deskflow-candidate "$DESK_BUILD/bin/deskflow" --deskflow-sha256 a14e44fb29656bc9e7107b6910b52c3650822751ecef5389ad98b58c740559c0 --deskflow-core-candidate "$DESK_BUILD/bin/deskflow-core" --deskflow-core-sha256 8dea6bd05c740177c80b6879929cdc058e3a2713772657318a0ea46c8620dad5
bundle_values=$(bundle_validator "$OP" "$COORD" "$ROOT" "$CAND" "$CANDIDATE_MANIFEST_SHA" "$HANDOFF" "$FROZEN" "$PUBLISH")
read -r manifest_sha marker_sha handoff_sha frozen_sha publish_sha replacement_terminal_sha replacement_commit_sha replacement_terminal_path replacement_commit_path <<<"$bundle_values"
[[ $manifest_sha == "$CANDIDATE_MANIFEST_SHA" && $marker_sha == "$MARKER_SHA" && $handoff_sha == "$HANDOFF_SHA" && $frozen_sha == "$FROZEN_SHA" && $publish_sha == "$PUBLISH_SHA" ]] || die 'fresh-boundary evidence changed or no longer closes'
[[ $replacement_terminal_sha == "$REPLACEMENT_TERMINAL_SHA" && $replacement_commit_sha == "$REPLACEMENT_COMMIT_SHA" && $replacement_terminal_path == "$REPLACEMENT_TERMINAL" && $replacement_commit_path == "$REPLACEMENT_COMMIT" ]] || die 'candidate replacement evidence changed or no longer closes'
[[ $mode == --check-only ]] && { printf 'normal v2.1 fresh-boundary checks passed\n'; exit 0; }
coordinator_mode=()
[[ $mode == --resume ]] && coordinator_mode+=(--resume)
coordinator_replacement=()
if [[ -n "$REPLACEMENT_TERMINAL" ]]; then
    coordinator_replacement+=(--candidate-retirement-terminal "$REPLACEMENT_TERMINAL" --candidate-retirement-terminal-sha256 "$REPLACEMENT_TERMINAL_SHA" --candidate-replacement-commit "$REPLACEMENT_COMMIT" --candidate-replacement-commit-sha256 "$REPLACEMENT_COMMIT_SHA")
fi
exec "$COORDINATOR" "${coordinator_mode[@]}" "${coordinator_replacement[@]}" \
 --viewflow-candidate "$RUST/release-target/release/viewflowd" --viewflow-sha256 0ed2dcf3c56565b9ce55349cf36f6cc0aba3dc8ff741fc864caf5c865ddba667 \
 --deployment-marker-candidate "$REVIEWED_MARKER" --deployment-marker-sha256 "$REVIEWED_MARKER_SHA" \
 --deskflow-candidate "$DESK_BUILD/bin/deskflow" --deskflow-sha256 a14e44fb29656bc9e7107b6910b52c3650822751ecef5389ad98b58c740559c0 \
 --deskflow-core-candidate "$DESK_BUILD/bin/deskflow-core" --deskflow-core-sha256 8dea6bd05c740177c80b6879929cdc058e3a2713772657318a0ea46c8620dad5 \
 --deskflow-acceptance-producer-sha256 8dea6bd05c740177c80b6879929cdc058e3a2713772657318a0ea46c8620dad5 --viewflow-acceptance-recorder-sha256 0ed2dcf3c56565b9ce55349cf36f6cc0aba3dc8ff741fc864caf5c865ddba667 \
 --deskflow-provenance-manifest "$DESK/deskflow-provenance.json" --deskflow-provenance-sha256 103d9d7561163f5c70ad42629c7ec8f8ae38ca307e475467d8e27bab12a03946 \
 --viewflow-unit-candidate "$RUST/source-stage/deploy/linux/viewflow-peer.service" --viewflow-unit-sha256 9b36f2e998ddade3746c0ca18fbe9633cfa39afde5b5de3d2887975a794b4315 \
 --deskflow-dropin-candidate "$RUST/source-stage/deploy/linux/deskflow-viewflow.conf" --deskflow-dropin-sha256 6af3e6d4a7156c58e21515c17227e804a4787e132e7310449cc267a1562a141d \
 --operation-id "$OP" --coordinator-instance-id "$COORD" --marker-generation 1 --recovery-marker-generation 2 \
 --source-display-id 00000000-0000-0000-0000-000000000101 --target-device-id 00000000-0000-0000-0000-000000000002 \
 --deployment-publish-receipt "$PUBLISH" --recovery-deployment-publish-receipt "$ROOT/recovery-deployment-publish.json" --deployment-release-receipt "$ROOT/deployment-release.json" \
 --cpp-status-response "$ROOT/cpp-status-response.json" --cpp-arm-response "$ROOT/cpp-arm-response.json" --cpp-cleanup-receipt "$ROOT/cpp-cleanup-receipt.json" \
 --rust-acceptance-arm-response "$ROOT/rust-acceptance-arm-response.json" --rust-acceptance-query-response "$ROOT/rust-acceptance-query-response.json" --post-release-receipt "$ROOT/post-release-receipt.json" --windows-restart-receipt "$ROOT/windows-restart-receipt.json" --linux-host-proof "$ROOT/linux-host-proof.json" \
 --bootstrap-linux-evidence "$FROZEN" --bootstrap-handoff-receipt "$HANDOFF" --windows-bootstrap-request "$ROOT/windows-bootstrap-request.json" --windows-prepared-receipt "$ROOT/windows-prepared.json" --windows-mutation-permit "$ROOT/windows-mutation-permit.json" --windows-force-release-envelope "$ROOT/windows-force-envelope.json" \
 --linux-stage-receipt "$ROOT/linux-stage.json" --linux-finalize-receipt "$ROOT/linux-finalize.json" --bootstrap-windows-install-receipt "$ROOT/windows-install.json" --windows-installer-exit-receipt "$ROOT/windows-installer-exit.json" --coordinator-state "$ROOT/coordinator-state.json" \
 --windows-viewflow-candidate "$CAND/windows-viewflowd.exe" --windows-viewflow-sha256 87631e877811377f018d65dc5ca2b1d6b68e2b268d7d15b8d0646aac3d9f5b04 \
 --windows-wrapper-candidate "$SRC/deploy/windows/viewflow-client.ps1" --windows-wrapper-sha256 2791c959914eb9bf5662577e52773a9bbb6d83a8015625fb938969715f74781a \
 --windows-launcher-candidate "$SRC/deploy/windows/start-viewflow-bootstrap.ps1" --windows-launcher-sha256 5880e945533d36c99200d6b0663ff9ffcdc465cdcff80d7b8ee6c59950ea4904 \
 --windows-installer-candidate "$SRC/deploy/windows/install-viewflow.ps1" --windows-installer-sha256 c73b7047fba9d23ae1bd195ba51c2ad48a5a4c3b8c47764b17170cbdf32da75e \
 --windows-rollback-script-sha256 f57a3a997eb69f9d99f8d4d0bc0c5f4766f6fc8c26835e0476340356ef0930eb --windows-user-sid S-1-5-21-1940417919-1835306932-1635351729-1001 \
 --linux-deactivation-transcript "$ROOT/linux-deactivation-transcript.json" --linux-deactivation-proof "$ROOT/linux-deactivation.json" --linux-containment-transcript "$ROOT/linux-containment.transcript" --local-windows-validation "$ROOT/windows-validation.json" --local-windows-rollback-receipt "$ROOT/windows-rollback.json" \
 --bootstrap-timeout-seconds 600 --acceptance-timeout-seconds 600
LAUNCHER
exec 3>&-
chmod 0500 -- "$output"
[[ $(stat -c '%a:%u:%h' -- "$output") == 500:1000:1 ]] || die 'generated launcher identity mismatch'
printf 'generated normal v2.1 launcher: %s\n' "$output"
