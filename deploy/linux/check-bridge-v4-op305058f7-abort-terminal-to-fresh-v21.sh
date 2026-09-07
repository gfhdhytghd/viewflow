#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
target=${1:-$(cd -- "$(dirname -- "$0")" && pwd)/bridge-v4-op305058f7-abort-terminal-to-fresh-v21.sh}
[[ -f $target && ! -L $target ]] || { printf 'error: bridge target missing or symlinked\n' >&2; exit 1; }
bash -n "$target"
shellcheck -x "$target"

/usr/bin/python3 -I - "$target" <<'PY'
import re,sys
s=open(sys.argv[1],encoding='utf-8').read()
def fail(message): raise SystemExit('error: '+message)
def need(token,label):
 if token not in s: fail(label+' anchor missing')
def body(name):
 matches=list(re.finditer(r'(?m)^'+re.escape(name)+r'\(\) \{',s))
 if not matches: fail(name+' missing')
 start=matches[-1].start()
 nxt=re.search(r'(?m)^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{|^main$',s[matches[-1].end():])
 end=len(s) if not nxt else matches[-1].end()+nxt.start()
 return s[start:end]

for token,label in (
 ('viewflow-failed-pre-mutation-no-retry-vfdqa-abort-terminal','V4 terminal state'),
 ('viewflow-deployment-quarantine-failed-pre-mutation-no-retry-abort-authorized','V4 authorization state'),
 ("receipt_keys='''abort_authorization_path",'native receipt exact-key contract'),
 ("q['replayed'] is not True",'query replay contract'),
 ("any(q[name]!=r[name] for name in receipt_keys if name!='replayed')",'query byte-semantic contract'),
 ('content-addressed V4 VFDQA path/binding differs','content-addressed VFDQA'),
 ('readonly REVIEWED_MARKER_SHA=e3c981f57a775d343c9e62a7d604a3d4aa3e79f3014e64c9ed8c9e6bbf1581f5','reviewed e3c981 marker'),
 ('readonly REVIEWED_MARKER_PROVENANCE_SHA=a0066c600c7f7a72292f7347eafaa702448ad216f7b91a081810876c684b19e8','reviewed marker provenance'),
 ('readonly REVIEWED_MARKER_MAIN_SOURCE_SHA=bb1a46ece72340ba85037180fd8ddebdf8d0d208458bf66a02b9e2a89378017b','reviewed marker main source'),
 ('readonly REVIEWED_MARKER_LIB_SOURCE_SHA=d7d6fee074c3a58b257f31dd95831de55243cd9b407d020c9bb8f9a3c7524d4a','reviewed marker library source'),
 ('readonly REVIEWED_MARKER_LINUX_SOURCE_SHA=57b5b73aa63c12e95a9dec9f8c380b5927a3ac97eccac61ec4be8881843fb664','reviewed marker Linux source'),
 ('readonly V4_OPERATION=305058f7deb84c198bad4103d6c4f946','frozen V4 operation'),
 ('readonly V4_MARKER_CLI_SHA=c237736c4d8d4db6ba6e118ac46dc083bdf3d8ae99a0b08716bc5d3206fc6c57','frozen V4 CLI'),
 ('readonly V4_PROVENANCE_SHA=3d14ca07a7706441b461599d77f504085e490c0ce0405fdb513c022f20114533','frozen V4 provenance'),
 ('readonly V4_MANIFEST_SHA=e2131a99e698a01e96a4796144d17d82405f418f2946b6e271815975d865b35c','frozen V4 manifest'),
 ('readonly V4_GATE_SHA=604b513283b3c3a0173985bcdf0e42c3c0106f5f962ad225fa5f4fad6f7ad8ff','frozen V4 gate'),
 ('readonly V4_LAUNCHER_SHA=6d24410d784393718e039e8c2da6cb096c1ac0be2814c92927c64985e1615527','frozen V4 launcher'),
 ('readonly V4_TERMINAL_SHA=9db787bc1a59b5a8b27e7d72e6d16349295a865b1ed1adef9ea9278a557d9384','frozen terminal'),
 ('readonly V4_EXECUTION_APPROVAL_SHA=6fe9f7d76b8a72b491a4f2898fb700a393e28c8826f90f43fb93eede24495b80','frozen execution approval'),
 ('readonly V4_AUTHORIZATION_SHA=dc7ce0350661902f3278b1e1e58ab487bb92d4953276d6160f33edd58a5ce706','frozen authorization'),
 ('readonly V4_ABORT_RECEIPT_SHA=1022759a0e265b7097c602b70c094eb3c8b7301c0d5254f9e6dd0fd859a4b230','frozen abort receipt'),
 ('readonly V4_ABORT_QUERY_RECEIPT_SHA=785fd373d20154b900a8a8f5b8fc569cb8d3fcf79f001a293cc967f6fe773506','frozen abort query receipt'),
 ('readonly V4_VFDQA_SHA=092d15a05ed77874d942f44f2697043013a1c5f94350de8610dcb4f8f5b63779','frozen VFDQA'),
 ("p['candidate']['size']==1003088",'frozen V4 CLI size'),
 ("p['candidate']['build_id']=='6b116abd3f6f7b33cf84deb1e404056741388685'",'frozen V4 CLI build ID'),
 ('os.O_NOFOLLOW','nofollow stable-open'),('F_ADD_SEALS','sealed execution'),('renameat2','no-replace publication'),
 ('VIEWFLOW_MARKER_LOCK_FD','marker lock inheritance'),('exec /usr/bin/env -i','outer marker-lock exec replacement'),
 ('KillMode) == control-group','effective unit KillMode'),('Restart) == on-failure','effective unit Restart'),
 ('DropInPaths','effective unit drop-ins'),("base+'/environ'",'persistent environment binding'),
 ('LD_PRELOAD','loader-variable denial'),('assert_process_census','system-wide process census'),
 ('--deployment-marker-candidate','prepare marker CLI contract'),('--daemon-pid','collector CLI contract')):
 need(token,label)

v=body('validate_inputs')
for token in ('terminal_keys=', 'approval_keys=', 'auth_keys=', 'receipt_keys=', "type(t['input_producer_count']) is int",
              'candidate_manifest_sha256', 'candidate_tree_sha256', 'candidate_retirement_terminal_sha256',
              'candidate_replacement_commit_sha256', 'coordinator_successor_receipt_sha256',
              'coordinator_successor_windows_prestate_sha256', 'successor_authorization_consumed',
              "e['candidate_replacement_commit_sha256']==t['candidate_replacement_commit_sha256']",
              "e['coordinator_successor_receipt_sha256']==t['coordinator_successor_receipt_sha256']",
              "e['coordinator_successor_windows_prestate_sha256']==t['coordinator_successor_windows_prestate_sha256']",
              "t['execution_approval_sha256']==approval_sha", "t['manifest_sha256']==manifest_sha", "t['gate_sha256']==gate_sha",
              "t['launcher_sha256']==launcher_sha", "e['manifest_sha256']==manifest_sha", "e['gate_sha256']==gate_sha",
              "e['launcher_sha256']==launcher_sha", "type(a[name]) is int", "t['vfdqa_binary_sha256']==vfdqa_sha",
              "p['candidate']['mode']=='0700'", "p['frozen_source_root']==os.path.dirname(v4_cli_path)+'/frozen-source'",
              'validate_vfdqa', 'import calendar,json,os,re,sys,time',
              '([0-9]{1,3})Z', "utc_ms(value['abort_committed_at_utc'],label)!=int(value['abort_committed_at_unix_ms'])",
              "[[ $old_operation == \"$V4_OPERATION\" ]] || die 'old operation is not the frozen 305058f7 V4 operation'",
              'failed-pre-mutation-abort-305058f7-no-retry-successor1-execution-approval.json',
              '[[ $terminal_sha == "$V4_TERMINAL_SHA" ]]',
              '[[ $execution_approval_sha == "$V4_EXECUTION_APPROVAL_SHA" ]]',
              '[[ $authorization_sha == "$V4_AUTHORIZATION_SHA" && $abort_receipt_sha == "$V4_ABORT_RECEIPT_SHA" &&',
              '$abort_query_sha == "$V4_ABORT_QUERY_RECEIPT_SHA" && $vfdqa_sha == "$V4_VFDQA_SHA" ]]'):
 if token not in v: fail('last validate_inputs lacks '+token)
if 'pre_mutation_retry' in v: fail('V4 input validator accepts retry fields')
for name in ('strict_json','exact_file','run_pinned_bash','snapshot_one'):
 if 'os.O_NOFOLLOW' not in body(name): fail(name+' lacks nofollow stable-open')
if 'F_ADD_SEALS' not in body('run_pinned_bash') or 'F_GET_SEALS' not in body('run_pinned_bash'):
 fail('pinned script execution lacks verified seals')
if 'renameat2' not in body('publish_new') or ',1)' not in body('publish_new'):
 fail('create-once publication lacks renameat2 NOREPLACE')

plan=body('validate_plan')
if '.new_operation_id!=$old' not in plan or '.new_coordinator_instance_id!=$old_coord' not in plan:
 fail('fresh operation/coordinator distinctness is not frozen')
if 'v4_marker_cli_provenance_sha256' not in plan or 'reviewed_marker_sha256' not in plan:
 fail('plan omits reviewed V4 inputs')
for token in ('mkdir -- "$fresh_root"','chmod 0700 "$fresh_root"','sync -f "$DEPLOYMENTS"',"safe_owner_dir 'fresh operation root' \"$fresh_root\""):
 if token not in plan: fail('plan validation does not materialize safe fresh root: '+token)

source=body('assert_source_inactive')
for token in ('ActiveState','SubState','MainPID','ControlGroup','assert_deskflow_zero 0','assert_claims_absent'):
 if token not in source: fail('inactive source proof lacks '+token)

census=body('assert_deskflow_zero')
if 'assert_process_census "$allowed_pid"' not in census:
 fail('production Deskflow zero boundary lacks global process census')

persistent=body('assert_persistent_unit_contract')
for token in ('DropInPaths','KillMode) == control-group','Restart) == on-failure'):
 if token not in persistent: fail('persistent effective unit contract lacks '+token)

prepare=body('invoke_prepare_contract')
if '--deployment-marker-candidate "$marker_candidate"' not in prepare:
 fail('pinned marker handoff invocation differs')
collector=body('invoke_collector_contract')
if '--daemon-pid "$(jq -er' not in collector:
 fail('pinned collector invocation differs')

intent=body('validate_persistent_start_intent')
if 'inactive_source_sha256' not in intent or 'old_stopped_sha256' in intent:
 fail('persistent intent is not bound to inactive source')

main=body('main')
order=['validate_inputs','ensure_roots','snapshot_inputs','make_plan','ensure_source_boundary','ensure_persistent_started','enter_marker_lock','ensure_marker_handoff','ensure_frozen','publish_final']
positions=[main.find(x) for x in order]
if min(positions)<0 or positions!=sorted(positions): fail('V4 main state-machine ordering differs')
if 'ensure_old_retired' in main or 'linux_started' in main or 'post_reattest' in main:
 fail('V4 main references transient retirement inputs')

final=body('publish_final')+body('validate_final')
for token in ('inactive_source','linux_initially_inactive:true','windows_old_peer_unchanged:true',
              'persistent_started_sha256','deployment_publish_sha256','marker_handoff_sha256','linux_frozen_sha256'):
 if token not in final: fail('final receipt lacks '+token)
if 'retirement' in final or 'old_stopped' in final: fail('V4 final receipt contains retirement evidence')
for name in ('validate_final','publish_final'):
 value=body(name)
 for token in ('linux_initially_inactive:true','windows_old_peer_unchanged:true'):
  if token not in value: fail(name+' does not freeze '+token)

locker=body('enter_marker_lock')
if 'exec /usr/bin/env -i' not in locker or 'os.execve' not in locker:
 fail('outer marker lock does not exec-replace')
print('V4 inactive-terminal bridge checker passed')
PY
