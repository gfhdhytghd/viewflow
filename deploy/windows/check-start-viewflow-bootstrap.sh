#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

launcher=${1:-deploy/windows/start-viewflow-bootstrap.ps1}
fixture=${2:-deploy/windows/test-start-viewflow-bootstrap.ps1}

for path in "$launcher" "$fixture"; do
    [[ -f $path ]] || { echo "missing bootstrap launcher artifact: $path" >&2; exit 1; }
done

require_launcher() {
    local pattern=$1 description=$2
    rg --quiet --multiline --multiline-dotall -- "$pattern" "$launcher" || {
        echo "bootstrap launcher missing $description" >&2
        exit 1
    }
}

require_fixture() {
    local pattern=$1 description=$2
    rg --quiet --multiline --multiline-dotall -- "$pattern" "$fixture" || {
        echo "bootstrap launcher fixture missing $description" >&2
        exit 1
    }
}

create_once_contract_present() {
    local candidate=$1
    rg --quiet --multiline --multiline-dotall -- \
        'function Write-OwnerSystemCreateOnceBytes.*FileSecurity\]::new.*FileStream\]::new.*\[IO\.FileMode\]::CreateNew.*\[IO\.FileShare\]::None.*\$acl.*\.Flush\(\$true\).*\[IO\.File\]::Move\(\$temporary, \$Path\)' \
        "$candidate" &&
        rg --quiet --multiline --multiline-dotall -- \
        'Write-OwnerSystemCreateOnceJson -Path \$claimPath.*Write-OwnerSystemCreateOnceJson -Path \$Request\.installer_exit_receipt_path' \
        "$candidate"
}

writer_has_no_set_acl() {
    local candidate=$1
    ! awk '
        /^function Write-OwnerSystemCreateOnceBytes/ { in_writer = 1; next }
        in_writer && /^function / { exit }
        in_writer { print }
    ' "$candidate" | rg --quiet --fixed-strings -- 'Set-Acl'
}

operation_acl_dispatch_contract_present() {
    local candidate=$1
    local set_calls assert_calls
    set_calls=$(rg --fixed-strings --count -- \
        'Set-AndAssert-OperationAcl -Path $operationRoot -OwnerSid $currentSid' \
        "$candidate")
    assert_calls=$(rg --fixed-strings --count -- \
        'Assert-OperationAcl -Path $operationRoot -OwnerSid $currentSid' \
        "$candidate")
    [[ $set_calls -eq 1 && $assert_calls -eq 2 ]] &&
        rg --quiet --multiline --multiline-dotall -- \
        'if \(\$Mode -ceq '\''Start'\''\) \{[[:space:]]*Set-AndAssert-OperationAcl -Path \$operationRoot -OwnerSid \$currentSid[[:space:]]*\} else \{[[:space:]]*Assert-OperationAcl -Path \$operationRoot -OwnerSid \$currentSid[[:space:]]*\}' \
        "$candidate"
}

worker_success_receipt_contract_present() {
    local candidate=$1
    rg --quiet --multiline --multiline-dotall -- \
        'function Invoke-Worker.*\.WaitForExit\(\).*\$exitCode = \[int\]\$child\.ExitCode.*if \(\$exitCode -eq 0\) \{.*Assert-OwnerOnlyRegularFile.*-Path \$Request\.install_success_receipt_path.*-OwnerSid \$CurrentSid.*Windows install-success receipt.*\}.*catch \{.*\$exitCode = 1' \
        "$candidate"
}

exact_request_contract_present() {
    local candidate=$1
    rg --quiet --multiline --multiline-dotall -- \
        'function Assert-BootstrapRequest.*Assert-ExactPropertySet -Value \$Request.*viewflow-windows-bootstrap-requested.*\^\[0-9a-f\]\{32\}\$.*Get-FixedOperationPaths.*RequireFreshOutputs.*must not exist before bootstrap' \
        "$candidate" &&
        rg --quiet --fixed-strings -- "'launcher_path', 'launcher_sha256'" "$candidate" &&
        rg --quiet --fixed-strings -- "'installer_path', 'installer_sha256'" "$candidate" &&
        rg --quiet --fixed-strings -- "'marker_handoff_receipt_path', 'marker_handoff_receipt_sha256'" "$candidate" &&
        rg --quiet --fixed-strings -- "'linux_frozen_evidence_path', 'linux_frozen_evidence_sha256'" "$candidate"
}

at_most_once_contract_present() {
    local candidate=$1
    rg --quiet --fixed-strings -- \
        'terminal receipt exists without its launcher claim' "$candidate" &&
        rg --quiet --fixed-strings -- \
        'uncertain: bootstrap task exists without a claim or terminal receipt' "$candidate" &&
        rg --quiet --fixed-strings -- \
        'uncertain: claimed launcher is dead and no terminal receipt exists' "$candidate" &&
        rg --quiet --fixed-strings -- \
        "if (\$Mode -ceq 'Start' -and \$status.State -ceq 'absent')" "$candidate" &&
        rg --quiet --fixed-strings -- 'Start-ScheduledTask' "$candidate" &&
        rg --quiet --fixed-strings -- \
        "if (\$Mode -ceq 'Start' -and \$status.State -ne 'absent')" "$candidate" &&
        rg --quiet --fixed-strings -- "\$Mode = 'Status'" "$candidate"
}

stop_contract_present() {
    local candidate=$1
    rg --quiet --multiline --multiline-dotall -- \
        'function Invoke-StopBootstrap.*Read-AndValidateClaim.*TaskXmlSha256.*Test-ClaimProcessLive.*Disable-ScheduledTask.*Stop-ScheduledTask.*Get-ClaimDescendantProcesses.*Assert-ExactProcessIdentityCurrent.*Stop-Process.*viewflow-windows-bootstrap-stopped.*installer_process_count = 0.*task_state = .Disabled.*Write-OwnerSystemCreateOnceJson -Path \$stopPath' \
        "$candidate" &&
        rg --quiet --multiline --multiline-dotall -- \
        'function Read-StopEvidence.*launcher stop evidence.*worker_process_start_filetime_utc.*installer_process_count.*task_state.*viewflow-windows-bootstrap-stopped' \
        "$candidate"
}

consumed_evidence_contract_present() {
    local candidate=$1
    rg --quiet --multiline --multiline-dotall -- \
        'function Get-ConsumedLinuxFrozenEvidencePath.*linux-v13-frozen-evidence\.consumed\.\{0\}\.json.*function Assert-BootstrapLinuxFrozenEvidence.*Get-ChildItem -LiteralPath \$OperationRoot -Force.*linux-v13-frozen-evidence\.consumed\.\*\.json.*if \(\$originalPresent\) \{.*if \(\$consumedCandidates\.Count -ne 0\).*original and consumed inputs must not coexist.*Assert-RegularPinnedInput -Path \$original.*Assert-OwnerOnlyRegularFile -Path \$original.*Linux frozen evidence original input is absent.*consumedCandidates\.Count -ne 1.*consumed input is not the unique fixed path.*Assert-RegularPinnedInput -Path \$expectedConsumed.*Assert-OwnerOnlyRegularFile -Path \$expectedConsumed' \
        "$candidate" &&
        rg --quiet --multiline --multiline-dotall -- \
        'function Assert-BootstrapRequest.*Assert-BootstrapLinuxFrozenEvidence -Request \$Request.*-AllowConsumedEvidence:\$AllowConsumedLinuxFrozenEvidence' \
        "$candidate" &&
        rg --quiet --fixed-strings -- \
        "-AllowConsumedLinuxFrozenEvidence:(\$Mode -cin @('Status', 'Stop'))" \
        "$candidate"
}

require_launcher '\[ValidateSet\(.Start., .Worker., .Status., .Stop.\)\].*\$Mode.*\$RequestPath' \
    'explicit start/worker/status/stop modes'
require_launcher 'Join-Path \$env:LOCALAPPDATA .Viewflow.Deployments.' \
    'fixed per-operation deployment root and request path'
require_launcher 'Join-Path \$deploymentRoot \$operationId.*Join-Path \$operationRoot .request\.json.' \
    'operation-id-derived request path'
require_launcher 'function Set-AndAssert-OperationAcl.*S-1-5-18.*SetAccessRuleProtection\(\$true, \$false\).*FullControl.*rules\.Count -ne 2' \
    'protected owner plus SYSTEM operation ACL'
require_launcher 'function Assert-OperationAcl.*Get-Acl.*AreAccessRulesProtected.*rules\.Count -ne 2' \
    'assert-only operation ACL verifier'
require_launcher 'function Assert-NoReparsePath.*ReparsePoint.*must not have a reparse-point ancestor' \
    'non-reparse ancestor validation'
require_launcher 'function Assert-OwnerOnlyRegularFile.*regular non-reparse file.*Assert-OwnerOnlyFileSecurity.*launcher claim.*installer exit receipt' \
    'owner-only claim and terminal security validation'
require_launcher 'function Read-StrictJsonBytes.*UTF8Encoding.*ConvertFrom-Json.*ConvertTo-Json -Compress.*canonical one-line UTF-8 with no duplicate keys' \
    'canonical duplicate-resistant UTF-8 JSON parser'
require_launcher 'function Get-FixedOperationPaths.*launcher_path.*installer_path.*candidate_path.*marker_handoff_receipt_path.*linux_frozen_evidence_path.*prepared_receipt_path.*mutation_permit_path.*raw_force_release_receipt_path.*force_release_envelope_path.*linux_stage_receipt_path.*install_success_receipt_path.*installer_exit_receipt_path.*rollback_manifest_path.*rollback_token_path' \
    'fixed H/B/P/permit/raw-F/F-envelope/Ls/W/exit/M/T paths'
require_launcher 'expected_session_id -ne 1.*CurrentSessionId -ne 1.*expected_peer.*expected_server_name.*expected_local_device_id.*expected_device_id.*expected_source_display_id' \
    'fixed SID/session/peer/device topology'
require_launcher 'function Get-TaskContract.*-Mode., .Worker., .-RequestPath.*CommandSha256' \
    'canonical worker task command hash'
require_launcher 'function Register-BootstrapTask.*New-ScheduledTaskAction.*New-ScheduledTaskPrincipal.*New-ScheduledTaskSettingsSet.*Register-ScheduledTask' \
    'one-shot task registration'
require_launcher 'function Assert-BootstrapTask.*\$triggers = @\(\$Task\.Triggers \| Where-Object \{ \$null -ne \$_ \}\).*\$triggers\.Count -ne 0.*\$actions\.Count -ne 1.*MultipleInstances -cne .IgnoreNew.*RestartCount.*-ne 0' \
    'trigger-free non-retrying task validation'
require_launcher 'function Get-InstallerContract.*.-BootstrapRequestPath.*RequestPath' \
    'request-only installer invocation'
require_launcher 'Start-Process -FilePath \$installerContract\.PowerShell.*-PassThru.*RedirectStandardOutput.*RedirectStandardError.*launcher-installer-process\.json.*\.WaitForExit\(\)' \
    'foreground installer child with durable logs'
require_launcher 'Join-Path \$env:SystemRoot .System32\\conhost\.exe' \
    'canonical System32 conhost descendant allowance'
require_launcher 'state = .viewflow-windows-bootstrap-claimed.*pid = \[int\]\$PID.*process_start_filetime_utc.*owner_sid.*session_id.*worker_executable_path.*launcher_path.*launcher_sha256.*request_sha256.*task_xml_sha256.*task_command_sha256.*installer_command_sha256' \
    'PID/start/SID/session/launcher/request/task/command claim binding'
require_launcher "viewflow-windows-bootstrap-succeeded.*viewflow-windows-bootstrap-failed.*exit_code.*claim_sha256.*completed_at_utc" \
    'create-once terminal exit union'
require_launcher 'launcher-installer-process\.json.*viewflow-windows-bootstrap-installer-running.*parent_pid.*process_start_filetime_utc.*installer_command_sha256' \
    'create-once exact installer child identity receipt'
worker_success_receipt_contract_present "$launcher" || {
    echo 'bootstrap worker must bind zero exit to an owner-only Windows success receipt' >&2
    exit 1
}
stop_contract_present "$launcher" || {
    echo 'bootstrap launcher lacks exact fail-closed Stop transaction' >&2
    exit 1
}
consumed_evidence_contract_present "$launcher" || {
    echo 'bootstrap launcher lacks consumed Linux frozen-evidence recovery contract' >&2
    exit 1
}

create_once_contract_present "$launcher" || {
    echo 'bootstrap launcher lacks create-once flush contract' >&2
    exit 1
}
writer_has_no_set_acl "$launcher" || {
    echo 'bootstrap launcher writer must not call Set-Acl' >&2
    exit 1
}
operation_acl_dispatch_contract_present "$launcher" || {
    echo 'bootstrap launcher must Set-AndAssert ACL only in Start and Assert otherwise' >&2
    exit 1
}
exact_request_contract_present "$launcher" || {
    echo 'bootstrap launcher lacks exact request contract' >&2
    exit 1
}
at_most_once_contract_present "$launcher" || {
    echo 'bootstrap launcher lacks monitor-only replay contract' >&2
    exit 1
}

require_fixture 'Parser\]::ParseFile.*parseErrors\.Count -ne 0' \
    'PS5.1 parser gate'
require_fixture 'PSVersionTable\.PSVersion\.Major -ne 5.*must run under Windows PowerShell 5\.1' \
    'actual Windows PowerShell 5.1 runtime gate'
require_fixture 'Stop descendant allowance must pin conhost to System32.*non-System32 conhost' \
    'conhost path pinning positive and negative fixture'
require_fixture 'unknown request field.*uppercase artifact hash.*non-fixed output path' \
    'strict schema/hash/path negative cases'
require_fixture 'create-once replay.*duplicate JSON key.*terminal receipt overwrite.*fresh outputs after terminal' \
    'create-once and terminal negative cases'
require_fixture 'registerHadTrigger.*Bootstrap task registration was not trigger-free' \
    'trigger-free registration mock'
require_fixture 'Set-AndAssert-OperationAcl call must occur exactly once.*Assert-OperationAcl call must occur exactly once.*only be reachable from Start.*FileSecurity.*writer must not call Set-Acl' \
    'ACL dispatch and secure writer AST contracts'
require_fixture 'Invoke-Worker must contain exactly one success receipt assertion.*success receipt assertion must be guarded by child exit code zero.*Windows success receipt must be owner-only regular' \
    'zero-exit Windows success receipt AST contract'
require_fixture 'Current launcher claim was not recognized as live.*Absent process was recognized as a live launcher claim' \
    'live/dead claim identity cases'
require_fixture 'viewflow-windows-bootstrap-stopped.*installer_process_count = 0.*task_state = .Disabled.*nonzero stopped installer process count' \
    'strict stop evidence replay and negative case'
require_fixture 'original plus consumed evidence.*Start or Worker consumed evidence.*wrong consumed evidence hash.*multiple consumed evidence candidates.*unsafe consumed evidence candidate' \
    'consumed Linux frozen-evidence positive and negative cases'
if rg --quiet -- '(ssh|Enter-PSSession|Invoke-Command|Start-ScheduledTask)' "$fixture"; then
    echo 'bootstrap launcher fixture must not touch SSH, live remoting, or start a task' >&2
    exit 1
fi

mutated=$(mktemp "${TMPDIR:-/tmp}/viewflow-bootstrap-create-mutation.XXXXXX.ps1")
sed '0,/\[IO\.FileMode\]::CreateNew/s//[IO.FileMode]::Create/' "$launcher" >"$mutated"
if cmp --silent -- "$launcher" "$mutated"; then
    rm -f -- "$mutated"
    echo 'could not construct CreateNew weakening mutation' >&2
    exit 1
fi
if create_once_contract_present "$mutated"; then
    rm -f -- "$mutated"
    echo 'launcher checker accepted CreateNew weakening mutation' >&2
    exit 1
fi
rm -f -- "$mutated"

mutated=$(mktemp "${TMPDIR:-/tmp}/viewflow-bootstrap-success-receipt-delete-mutation.XXXXXX.ps1")
sed '/Assert-OwnerOnlyRegularFile `/,/Windows install-success receipt/d' \
    "$launcher" >"$mutated"
if cmp --silent -- "$launcher" "$mutated"; then
    rm -f -- "$mutated"
    echo 'could not construct success receipt assertion deletion mutation' >&2
    exit 1
fi
if worker_success_receipt_contract_present "$mutated"; then
    rm -f -- "$mutated"
    echo 'launcher checker accepted missing success receipt assertion' >&2
    exit 1
fi
rm -f -- "$mutated"

mutated=$(mktemp "${TMPDIR:-/tmp}/viewflow-bootstrap-success-receipt-testpath-mutation.XXXXXX.ps1")
sed '/Assert-OwnerOnlyRegularFile `/,/Windows install-success receipt/c\            Test-Path -LiteralPath $Request.install_success_receipt_path | Out-Null' \
    "$launcher" >"$mutated"
if cmp --silent -- "$launcher" "$mutated"; then
    rm -f -- "$mutated"
    echo 'could not construct success receipt Test-Path weakening mutation' >&2
    exit 1
fi
if worker_success_receipt_contract_present "$mutated"; then
    rm -f -- "$mutated"
    echo 'launcher checker accepted Test-Path-only success receipt check' >&2
    exit 1
fi
rm -f -- "$mutated"

mutated=$(mktemp "${TMPDIR:-/tmp}/viewflow-bootstrap-acl-mutation.XXXXXX.ps1")
sed "0,/if (\$Mode -ceq 'Start')/s//if (\$Mode -ceq 'Worker')/" \
    "$launcher" >"$mutated"
if cmp --silent -- "$launcher" "$mutated"; then
    rm -f -- "$mutated"
    echo 'could not construct Start-only ACL weakening mutation' >&2
    exit 1
fi
if operation_acl_dispatch_contract_present "$mutated"; then
    rm -f -- "$mutated"
    echo 'launcher checker accepted non-Start Set-AndAssert ACL mutation' >&2
    exit 1
fi
rm -f -- "$mutated"

mutated=$(mktemp "${TMPDIR:-/tmp}/viewflow-bootstrap-writer-acl-mutation.XXXXXX.ps1")
sed '0,/\[IO.File\]::Move(\$temporary, \$Path)/s//Set-Acl -LiteralPath \$Path -AclObject \$acl\n        [IO.File]::Move(\$temporary, \$Path)/' \
    "$launcher" >"$mutated"
if cmp --silent -- "$launcher" "$mutated"; then
    rm -f -- "$mutated"
    echo 'could not construct writer Set-Acl mutation' >&2
    exit 1
fi
if writer_has_no_set_acl "$mutated"; then
    rm -f -- "$mutated"
    echo 'launcher checker accepted writer Set-Acl mutation' >&2
    exit 1
fi
rm -f -- "$mutated"

mutated=$(mktemp "${TMPDIR:-/tmp}/viewflow-bootstrap-replay-mutation.XXXXXX.ps1")
sed "0,/\$status.State -ceq 'absent'/s//\$status.State -ne 'terminal'/" \
    "$launcher" >"$mutated"
if cmp --silent -- "$launcher" "$mutated"; then
    rm -f -- "$mutated"
    echo 'could not construct replay weakening mutation' >&2
    exit 1
fi
if at_most_once_contract_present "$mutated"; then
    rm -f -- "$mutated"
    echo 'launcher checker accepted replay weakening mutation' >&2
    exit 1
fi
rm -f -- "$mutated"

mutated=$(mktemp "${TMPDIR:-/tmp}/viewflow-bootstrap-stop-mutation.XXXXXX.ps1")
sed '0,/installer_process_count = 0/s//installer_process_count = 1/' \
    "$launcher" >"$mutated"
if cmp --silent -- "$launcher" "$mutated"; then
    rm -f -- "$mutated"
    echo 'could not construct zero-process Stop weakening mutation' >&2
    exit 1
fi
if stop_contract_present "$mutated"; then
    rm -f -- "$mutated"
    echo 'launcher checker accepted nonzero Stop process evidence' >&2
    exit 1
fi
rm -f -- "$mutated"

mutated=$(mktemp "${TMPDIR:-/tmp}/viewflow-bootstrap-consumed-evidence-mutation.XXXXXX.ps1")
sed '0,/if (\$originalPresent) {/s//if (\$false) {/' "$launcher" >"$mutated"
if cmp --silent -- "$launcher" "$mutated"; then
    rm -f -- "$mutated"
    echo 'could not construct consumed evidence original-presence mutation' >&2
    exit 1
fi
if consumed_evidence_contract_present "$mutated"; then
    rm -f -- "$mutated"
    echo 'launcher checker accepted consumed evidence original-presence mutation' >&2
    exit 1
fi
rm -f -- "$mutated"

echo 'viewflow Windows bootstrap launcher checker passed'
