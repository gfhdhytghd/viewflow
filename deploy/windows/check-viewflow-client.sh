#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

script=${1:-deploy/windows/viewflow-client.ps1}
installer=${2:-deploy/windows/install-viewflow.ps1}
rollback=${3:-deploy/windows/rollback-viewflow.ps1}
rollback_test=${4:-deploy/windows/test-rollback-viewflow-static.ps1}
marker_test=${5:-deploy/windows/test-quiesced-marker.ps1}
readiness_disconnect_test=${6:-deploy/windows/test-readiness-disconnect-before-commit.ps1}
readiness_close_test=${7:-deploy/windows/test-readiness-lease-close.ps1}
installer_union_test=${8:-deploy/windows/test-installer-rollback-union.ps1}
rollback_contract_test=${9:-deploy/windows/test-rollback-viewflow-contract.ps1}
force_release_contract_test=${10:-deploy/windows/test-force-release-receipt-contract.ps1}
bootstrap_prepared_test=${11:-deploy/windows/test-bootstrap-recovery-prepared.ps1}
bootstrap_chain_test=${12:-deploy/windows/test-bootstrap-chain-contract.ps1}
install_success_schema5_test=${13:-deploy/windows/test-install-success-schema5.ps1}
atomic_replace_test=${14:-deploy/windows/test-installer-atomic-replace.ps1}
bootstrap_force_task_test=${15:-deploy/windows/test-bootstrap-force-release-task.ps1}

if [[ ! -f "$script" ]]; then
    echo "missing PowerShell wrapper: $script" >&2
    exit 1
fi
if [[ ! -f "$installer" ]]; then
    echo "missing PowerShell installer: $installer" >&2
    exit 1
fi
if [[ ! -f "$rollback" ]]; then
    echo "missing standalone PowerShell rollback tool: $rollback" >&2
    exit 1
fi
if [[ ! -f "$rollback_test" ]]; then
    echo "missing standalone rollback static test: $rollback_test" >&2
    exit 1
fi
if [[ ! -f "$marker_test" ]]; then
    echo "missing quiesced-marker fixture: $marker_test" >&2
    exit 1
fi
if [[ ! -f "$readiness_disconnect_test" ]]; then
    echo "missing readiness disconnect fixture: $readiness_disconnect_test" >&2
    exit 1
fi
if [[ ! -f "$readiness_close_test" ]]; then
    echo "missing readiness lease-close fixture: $readiness_close_test" >&2
    exit 1
fi
if [[ ! -f "$installer_union_test" ]]; then
    echo "missing installer rollback-union fixture: $installer_union_test" >&2
    exit 1
fi
if [[ ! -f "$rollback_contract_test" ]]; then
    echo "missing rollback contract fixture: $rollback_contract_test" >&2
    exit 1
fi
if [[ ! -f "$force_release_contract_test" ]]; then
    echo "missing force-release receipt fixture: $force_release_contract_test" >&2
    exit 1
fi
for fixture in \
    "$bootstrap_prepared_test" \
    "$bootstrap_chain_test" \
    "$install_success_schema5_test" \
    "$atomic_replace_test" \
    "$bootstrap_force_task_test"; do
    if [[ ! -f "$fixture" ]]; then
        echo "missing Windows bootstrap fixture: $fixture" >&2
        exit 1
    fi
done
if ! rg --quiet --multiline --multiline-dotall -- \
    '& \$CargoPath test --locked --offline --manifest-path .*force_release_receipt_contract' \
    "$force_release_contract_test"; then
    echo 'force-release fixture must invoke Cargo with --locked --offline' >&2
    exit 1
fi
if ! rg --quiet --multiline --multiline-dotall -- \
    'Get-BootstrapForceReleaseDeadlineFailure.*DispatchElapsedSeconds 31.*never-dispatched.*cleanup-failure.*history-disabled' \
    "$bootstrap_force_task_test"; then
    echo 'bootstrap force-release task fixture is missing deadline or failure coverage' >&2
    exit 1
fi

require() {
    local pattern=$1
    local description=$2
    if ! rg --quiet --multiline -- "$pattern" "$script"; then
        echo "missing $description" >&2
        exit 1
    fi
}

require_installer() {
    local pattern=$1
    local description=$2
    if ! rg --quiet --multiline --multiline-dotall -- "$pattern" "$installer"; then
        echo "installer missing $description" >&2
        exit 1
    fi
}

exact_property_set_contract_present() {
    local candidate_installer=$1 block
    block=$(awk '
        /^function Assert-ExactPropertySet \{$/ { found = 1 }
        found && /^function / && $0 !~ /^function Assert-ExactPropertySet \{$/ { exit }
        found { print }
    ' "$candidate_installer")
    [[ -n "$block" ]] &&
        rg --quiet --multiline --multiline-dotall -- \
            '\$actual = .*PSObject\.Properties.*ForEach-Object Name.*\$expected = .*\$Names.*Compare-Object -CaseSensitive.*-ReferenceObject \$expected -DifferenceObject \$actual' \
            <<<"$block"
}

run_exact_property_set_weakening_mutation() {
    local mutated_installer
    mutated_installer=$(mktemp \
        "${TMPDIR:-/tmp}/viewflow-installer-exact-set-mutation.XXXXXX.ps1")
    awk '
        /^function Assert-ExactPropertySet \{$/ { in_contract = 1 }
        in_contract && !changed && /Compare-Object -CaseSensitive/ {
            sub(/Compare-Object -CaseSensitive/, "Compare-Object")
            changed = 1
        }
        in_contract && /^function / && $0 !~ /^function Assert-ExactPropertySet \{$/ {
            in_contract = 0
        }
        { print }
    ' "$installer" >"$mutated_installer"
    if cmp --silent -- "$installer" "$mutated_installer"; then
        rm -f -- "$mutated_installer"
        echo 'could not construct case-insensitive exact-set mutation' >&2
        exit 1
    fi
    if exact_property_set_contract_present "$mutated_installer"; then
        rm -f -- "$mutated_installer"
        echo 'installer checker accepted case-insensitive exact property sets' >&2
        exit 1
    fi
    rm -f -- "$mutated_installer"
}

task_action_parser_contract_present() {
    local candidate_installer=$1

    rg --quiet --fixed-strings -- 'function Split-WindowsCommandLine {' \
        "$candidate_installer" &&
        rg --quiet --fixed-strings -- \
            '$arguments = New-Object System.Collections.Generic.List[string]' \
            "$candidate_installer" &&
        rg --quiet --fixed-strings -- \
            "throw 'Command line contains an unterminated quote'" \
            "$candidate_installer" &&
        rg --quiet --fixed-strings -- '$arguments.ToArray()' \
            "$candidate_installer" &&
        rg --quiet --multiline --multiline-dotall -- \
            'function Assert-ExactArguments.*\$Actual\.Count -ne \$Expected\.Count.*for \(\$index = 0; \$index -lt \$Expected\.Count; \$index\+\+\).*\$Actual\[\$index\].*\.Equals\(.*\$Expected\[\$index\].*\$comparison.*unexpected token at index \$index' \
            "$candidate_installer" &&
        rg --quiet --multiline --multiline-dotall -- \
            'function Assert-TaskActionArguments.*\$actual = @\(Split-WindowsCommandLine -CommandLine \$Arguments\).*\$base = @\(\s*.-NoProfile., .-NonInteractive., .-ExecutionPolicy., .Bypass.,\s*.-WindowStyle., .Hidden., .-File., \$installedScript\s*\).*\$current = \$base \+ @\(.*.-ReadinessReceiptPath., \$expectedReadinessReceiptPath.*.-ReadinessLockPath., \$expectedReadinessLockPath.*.-ReadinessCommitRequestPath., \$expectedReadinessCommitRequestPath.*.-InstallSuccessReceiptPath., \$expectedInstallSuccessReceiptPath.*.-OperationId., \$expectedOperationId.*Assert-ExactArguments -Actual \$actual -Expected \$current.*-PathIndexes @\(.7., .9., .11., .13., .15.\)' \
            "$candidate_installer" &&
        rg --quiet --multiline --multiline-dotall -- \
            '\$actionArguments = \(\s*.-NoProfile -NonInteractive -ExecutionPolicy Bypass .*\+\s*.-WindowStyle Hidden -File .*\+\s*.-ReadinessReceiptPath .* -ReadinessLockPath .*\+\s*.-ReadinessCommitRequestPath .*\+\s*.-InstallSuccessReceiptPath .* -OperationId' \
            "$candidate_installer"
}

run_task_action_parser_weakening_mutation() {
    local mutated_installer

    mutated_installer=$(mktemp \
        "${TMPDIR:-/tmp}/viewflow-installer-parser-mutation.XXXXXX.ps1")
    sed \
        '0,/\$Actual\.Count -ne \$Expected\.Count/s//\$Actual.Count -lt \$Expected.Count/' \
        "$installer" >"$mutated_installer"
    if cmp --silent -- "$installer" "$mutated_installer"; then
        rm -f -- "$mutated_installer"
        echo 'could not construct strict argument-count parser mutation' >&2
        exit 1
    fi
    if task_action_parser_contract_present "$mutated_installer"; then
        rm -f -- "$mutated_installer"
        echo 'installer checker accepted weakened task-action argument parser' >&2
        exit 1
    fi
    rm -f -- "$mutated_installer"
}

bootstrap_two_phase_contract_present() {
    local candidate_installer=$1
    rg --quiet --multiline --multiline-dotall -- \
        '\$bootstrapRecoveryPreparedReceipt =.*Write-BootstrapRecoveryPreparedReceipt.*\$bootstrapMutationPermit = Wait-BootstrapMutationPermit.*\$consumedEvidence = Move-ConsumedEvidence.*Stop-ViewflowTaskAndWait.*Invoke-BootstrapForceRelease.*\$bootstrapForceReleaseEnvelope =.*Replace-FileAtomically -Source \$CandidatePath' \
        "$candidate_installer" &&
        rg --quiet --multiline --multiline-dotall -- \
        'staged_viewflowd -cne\s*\[string\]\$MutationPermit\.linux_viewflowd_sha256.*staged_deployment_marker_tool -cne\s*\[string\]\$MutationPermit\.linux_deployment_marker_sha256.*staged_viewflow_unit -cne\s*\[string\]\$MutationPermit\.linux_viewflow_unit_sha256' \
        "$candidate_installer" &&
        rg --quiet --multiline --multiline-dotall -- \
        '\$bootstrapHashSeen\.ContainsKey\(\[string\]\$bootstrapHash\).*must be pairwise distinct.*Normal readiness commit request must use null bootstrap hashes.*\$receiptBootstrapSeen\.ContainsKey\(\[string\]\$value\).*Bootstrap install-success hashes must be pairwise distinct' \
        "$candidate_installer" &&
        bootstrap_journal_boot_id_contract_present "$candidate_installer"
}

bootstrap_journal_boot_id_contract_present() {
    local candidate_installer=$1
    rg --quiet --fixed-strings -- \
        "\$expectedJournalQueryBootId = ([string]\$daemon.boot_id).Replace('-', '')" \
        "$candidate_installer" &&
        rg --quiet --fixed-strings -- \
        "\$journal.query_boot_id -cnotmatch '^[0-9a-f]{32}\$'" \
        "$candidate_installer" &&
    rg --quiet --fixed-strings -- \
        "\$journal.query_boot_id -cne \$expectedJournalQueryBootId" \
        "$candidate_installer"
}

backup_acl_contract_present() {
    local candidate_installer=$1 candidate_rollback=$2
    rg --quiet --multiline --multiline-dotall -- \
        'function Set-OwnerOnlyFileSecurity.*Assert-RegularNonReparseFile.*Set-Acl -LiteralPath \$Path -AclObject \(New-OwnerOnlyFileSecurity\).*Assert-OwnerOnlyFileSecurity.*Copy-Item -LiteralPath \$installedBinary -Destination \$backupBinary.*Set-OwnerOnlyFileSecurity -Path \$backupBinary.*Copy-Item -LiteralPath \$installedScript -Destination \$backupScript.*Set-OwnerOnlyFileSecurity -Path \$backupScript.*Copy-Item -LiteralPath \$CandidatePath -Destination \$backupForceReleaseTool.*Set-OwnerOnlyFileSecurity -Path \$backupForceReleaseTool.*if \(\(Get-FileSha256Lower -Path \$backupBinary' \
        "$candidate_installer" &&
        rg --quiet --multiline --multiline-dotall -- \
            '\$backupAclBinding in @\(.*\$backupBinary.*\$backupWrapper.*\$forceReleaseTool.*Assert-OwnerOnlyFileSecurity -Path \$backupAclBinding\.Path.*if \(\$ValidateOnly\)' \
            "$candidate_rollback"
}

run_backup_acl_mutations() {
    local mutated_installer mutated_rollback
    mutated_installer=$(mktemp \
        "${TMPDIR:-/tmp}/viewflow-installer-backup-acl.XXXXXX.ps1")
    mutated_rollback=$(mktemp \
        "${TMPDIR:-/tmp}/viewflow-rollback-backup-acl.XXXXXX.ps1")
    sed '0,/Set-OwnerOnlyFileSecurity -Path \$backupBinary/s//Write-Verbose skipped-backup-binary-acl/' \
        "$installer" >"$mutated_installer"
    cp -- "$rollback" "$mutated_rollback"
    if cmp --silent -- "$installer" "$mutated_installer"; then
        rm -f -- "$mutated_installer" "$mutated_rollback"
        echo 'could not construct installer backup ACL mutation' >&2
        exit 1
    fi
    if backup_acl_contract_present "$mutated_installer" "$mutated_rollback"; then
        rm -f -- "$mutated_installer" "$mutated_rollback"
        echo 'installer checker accepted a backup copied without ACL normalization' >&2
        exit 1
    fi
    cp -- "$installer" "$mutated_installer"
    sed '0,/Assert-OwnerOnlyFileSecurity -Path \$backupAclBinding.Path/s//Write-Verbose skipped-backup-acl-validation/' \
        "$rollback" >"$mutated_rollback"
    if cmp --silent -- "$rollback" "$mutated_rollback"; then
        rm -f -- "$mutated_installer" "$mutated_rollback"
        echo 'could not construct rollback ValidateOnly backup ACL mutation' >&2
        exit 1
    fi
    if backup_acl_contract_present "$mutated_installer" "$mutated_rollback"; then
        rm -f -- "$mutated_installer" "$mutated_rollback"
        echo 'installer checker accepted ValidateOnly without backup ACL validation' >&2
        exit 1
    fi
    rm -f -- "$mutated_installer" "$mutated_rollback"
}

run_bootstrap_two_phase_mutations() {
    local mutated_installer mutation
    for mutation in permit-gate staged-candidate schema5-distinct journal-boot-id; do
        mutated_installer=$(mktemp \
            "${TMPDIR:-/tmp}/viewflow-bootstrap-${mutation}.XXXXXX.ps1")
        case $mutation in
            permit-gate)
                sed '0,/\$bootstrapMutationPermit = Wait-BootstrapMutationPermit/s//\$bootstrapMutationPermit = Bypass-BootstrapMutationPermit/' \
                    "$installer" >"$mutated_installer"
                ;;
            staged-candidate)
                sed '0,/staged_viewflowd -cne/s//staged_viewflowd -ceq/' \
                    "$installer" >"$mutated_installer"
                ;;
            schema5-distinct)
                sed '0,/\$bootstrapHashSeen\.ContainsKey(\[string\]\$bootstrapHash)/s//\$false/' \
                    "$installer" >"$mutated_installer"
                ;;
            journal-boot-id)
                sed '0,/query_boot_id -cnotmatch/s//query_boot_id -cmatch/' \
                    "$installer" >"$mutated_installer"
                ;;
        esac
        if cmp --silent -- "$installer" "$mutated_installer"; then
            rm -f -- "$mutated_installer"
            echo "could not construct bootstrap negative mutation: $mutation" >&2
            exit 1
        fi
        if bootstrap_two_phase_contract_present "$mutated_installer"; then
            rm -f -- "$mutated_installer"
            echo "installer checker accepted bootstrap negative mutation: $mutation" >&2
            exit 1
        fi
        rm -f -- "$mutated_installer"
    done
}

bootstrap_force_release_task_contract_present() {
    local candidate=$1 block
    block=$(awk '
        /^function Invoke-BootstrapForceRelease \{$/ { found = 1 }
        found && /^function / && $0 !~ /^function Invoke-BootstrapForceRelease \{$/ { exit }
        found { print }
    ' "$candidate")
    [[ -n "$block" ]] || return 1
    rg --quiet --multiline --multiline-dotall -- \
        'Register-ScheduledTask -TaskPath \$bootstrapTaskPath -TaskName \$bootstrapTaskName' \
        <<<"$block" &&
        rg --quiet --multiline --multiline-dotall -- \
            '-Action \$action.*-Principal \$principal.*-Settings \$settings \| Out-Null' \
            <<<"$block" &&
        rg --quiet --multiline --multiline-dotall -- \
            'Get-BootstrapForceReleaseAttemptSnapshot' <<<"$block" &&
        rg --quiet --multiline --multiline-dotall -- \
            '-ObservedPid .*observedPid.*-ObservedProcessStartFileTime \$observedStartFileTime' \
            <<<"$block" &&
        rg --quiet --multiline --multiline-dotall -- \
            'snapshot_error_chain.*cleanupFailures' \
            <<<"$block"
}

run_bootstrap_force_release_task_mutations() {
    local mutated
    mutated=$(mktemp "${TMPDIR:-/tmp}/viewflow-bootstrap-force-task.XXXXXX.ps1")
    sed '0,/ -Action \$action -Principal \$principal -Settings \$settings | Out-Null/s// -Action $action -Principal $principal -Settings $settings -Force | Out-Null/' \
        "$installer" >"$mutated"
    if cmp --silent -- "$installer" "$mutated"; then
        rm -f -- "$mutated"
        echo 'could not construct bootstrap force-release no-clobber mutation' >&2
        exit 1
    fi
    if bootstrap_force_release_task_contract_present "$mutated"; then
        rm -f -- "$mutated"
        echo 'installer checker accepted bootstrap force-release task Force mutation' >&2
        exit 1
    fi
    rm -f -- "$mutated"
}

bootstrap_force_release_deadline_contract_present() {
    local candidate=$1
    rg --quiet --multiline --multiline-dotall -- \
        'function Get-BootstrapForceReleaseMonotonicSeconds.*\$dispatchStartedSeconds = Get-BootstrapForceReleaseMonotonicSeconds.*\$executionStartedSeconds = \$null.*\$executionStartedSeconds = \$nowSeconds.*-DispatchElapsedSeconds \(\$nowSeconds - \$dispatchStartedSeconds\).*-ExecutionElapsedSeconds.*\$nowSeconds - \$executionStartedSeconds' \
        "$candidate"
}

run_bootstrap_force_release_deadline_mutation() {
    local mutated
    mutated=$(mktemp "${TMPDIR:-/tmp}/viewflow-bootstrap-force-deadline.XXXXXX.ps1")
    sed '0,/\$nowSeconds - \$executionStartedSeconds/s//\$nowSeconds - \$dispatchStartedSeconds/' \
        "$installer" >"$mutated"
    if cmp --silent -- "$installer" "$mutated"; then
        rm -f -- "$mutated"
        echo 'could not construct bootstrap execution-clock swap mutation' >&2
        exit 1
    fi
    if bootstrap_force_release_deadline_contract_present "$mutated"; then
        rm -f -- "$mutated"
        echo 'installer checker accepted bootstrap execution clock swap mutation' >&2
        exit 1
    fi
    rm -f -- "$mutated"
}

force_release_observed_identity_contract_present() {
    local candidate=$1 block
    block=$(awk '
        /^function Assert-ForceReleaseReceipt \{$/ { found = 1 }
        found && /^function / && $0 !~ /^function Assert-ForceReleaseReceipt \{$/ { exit }
        found { print }
    ' "$candidate")
    [[ -n "$block" ]] &&
        rg --quiet --multiline --multiline-dotall -- \
            'if \(\$ObservedPid -gt 0 -and.*\[long\]\$receipt\.tool_pid -ne \$ObservedPid.*tool_process_start_filetime -cne.*ObservedProcessStartFileTime.*throw .Force-release receipt does not match the observed tool process identity' \
            <<<"$block"
}

run_force_release_observed_identity_mutation() {
    local mutated
    mutated=$(mktemp "${TMPDIR:-/tmp}/viewflow-force-observed-identity.XXXXXX.ps1")
    sed '0,/if (\$ObservedPid -gt 0 -and/s//if ($false -and/' \
        "$installer" >"$mutated"
    if cmp --silent -- "$installer" "$mutated"; then
        rm -f -- "$mutated"
        echo 'could not construct observed force-release identity mutation' >&2
        exit 1
    fi
    if force_release_observed_identity_contract_present "$mutated"; then
        rm -f -- "$mutated"
        echo 'installer checker accepted observed force-release identity mutation' >&2
        exit 1
    fi
    rm -f -- "$mutated"
}

require_rollback() {
    local pattern=$1
    local description=$2
    if ! rg --quiet --multiline --multiline-dotall -- "$pattern" "$rollback"; then
        echo "rollback tool missing $description" >&2
        exit 1
    fi
}

require_rollback_test() {
    local pattern=$1
    local description=$2
    if ! rg --quiet --multiline --multiline-dotall -- "$pattern" "$rollback_test"; then
        echo "rollback test missing $description" >&2
        exit 1
    fi
}

require_readiness_disconnect_test() {
    local pattern=$1
    local description=$2
    if ! rg --quiet --multiline --multiline-dotall -- "$pattern" \
        "$readiness_disconnect_test"; then
        echo "readiness disconnect fixture missing $description" >&2
        exit 1
    fi
}

require_readiness_close_test() {
    local pattern=$1
    local description=$2
    if ! rg --quiet --multiline --multiline-dotall -- "$pattern" \
        "$readiness_close_test"; then
        echo "readiness lease-close fixture missing $description" >&2
        exit 1
    fi
}

require_installer_union_test() {
    local pattern=$1
    local description=$2
    if ! rg --quiet --multiline --multiline-dotall -- "$pattern" \
        "$installer_union_test"; then
        echo "installer rollback-union fixture missing $description" >&2
        exit 1
    fi
}

require_atomic_replace_test() {
    local pattern=$1
    local description=$2
    if ! rg --quiet --multiline --multiline-dotall -- "$pattern" \
        "$atomic_replace_test"; then
        echo "atomic replacement fixture missing $description" >&2
        exit 1
    fi
}

require_rollback_contract_test() {
    local pattern=$1
    local description=$2
    if ! rg --quiet --multiline --multiline-dotall -- "$pattern" \
        "$rollback_contract_test"; then
        echo "rollback contract fixture missing $description" >&2
        exit 1
    fi
}

rollback_recovery_contract_present() {
    local candidate=$1
    rg --quiet --fixed-strings -- \
        '-LogonType Interactive -RunLevel Limited' "$candidate" &&
        rg --quiet --fixed-strings -- \
            'Start-ScheduledTask -TaskPath $contract.TaskPath' "$candidate" &&
        rg --quiet --fixed-strings -- \
            'Assert-RecoveryForceReleaseProcess -Process $processes[0]' \
            "$candidate" &&
        rg --quiet --fixed-strings -- \
            'Assert-ForceReleaseReceipt -Path $ReceiptPath' "$candidate" &&
        rg --quiet --multiline --multiline-dotall -- \
            'finally \{.*Stop-ScheduledTask -TaskPath \$contract\.TaskPath.*Wait-RecoveryForceReleaseProcessAbsent.*Unregister-ScheduledTask -TaskPath \$contract\.TaskPath.*one-shot task was not removed' \
            "$candidate" &&
        rg --quiet --fixed-strings -- \
            'Assert-RecoveryForceReleasePreflight -Contract $forceReleaseTaskContract' \
            "$candidate" &&
        rg --quiet --multiline --multiline-dotall -- \
            '\[System\.IO\.File\]::Replace\(.*\$temporary,.*\$Destination,.*\$replacementBackup,.*\$true.*\[System\.IO\.File\]::Replace\(.*\$replacementBackup,.*\$Destination,.*\$failedReplacement,.*\$true' \
            "$candidate" &&
        rg --quiet --fixed-strings -- \
            "Name = 'Backup binary transaction source'" "$candidate" &&
        rg --quiet --fixed-strings -- \
            "Name = 'Backup wrapper transaction source'" "$candidate" &&
        rg --quiet --multiline --multiline-dotall -- \
            '\$allowLegacyCurrentTask = \(.*\$currentBinarySha256 -ceq \[string\]\$manifest\.backup\.binary_sha256 -and.*\$currentWrapperSha256 -ceq \[string\]\$manifest\.backup\.wrapper_sha256.*Assert-CurrentRollbackBoundary.*-AllowLegacyLogonTrigger:\$allowLegacyCurrentTask' \
            "$candidate" &&
        rg --quiet --multiline --multiline-dotall -- \
            'function Assert-CurrentRollbackBoundary.*\[switch\]\$AllowLegacyLogonTrigger.*Assert-RestoredScheduledTaskContract.*-AllowLegacyLogonTrigger:\$AllowLegacyLogonTrigger' \
            "$candidate" &&
        ! rg --quiet --multiline --multiline-dotall -- \
            '\[System\.IO\.File\]::Replace\(\s*\$temporary,\s*\$Destination,\s*\$null' \
            "$candidate"
}

run_rollback_recovery_mutations() {
    local mutation mutated
    for mutation in session0 direct-process null-replace skip-preflight \
        skip-unregister unlock-backup legacy-recovery-disabled \
        legacy-recovery-unbound; do
        mutated=$(mktemp \
            "${TMPDIR:-/tmp}/viewflow-rollback-${mutation}.XXXXXX.ps1")
        case $mutation in
            session0)
                sed '0,/-LogonType Interactive -RunLevel Limited/s//-LogonType ServiceAccount -RunLevel Highest/' \
                    "$rollback" >"$mutated"
                ;;
            direct-process)
                sed '0,/Start-ScheduledTask -TaskPath \$contract.TaskPath/s//Start-Process -FilePath \$contract.ToolPath/' \
                    "$rollback" >"$mutated"
                ;;
            null-replace)
                sed '0,/^[[:space:]]*\$replacementBackup,$/s//            \$null,/' \
                    "$rollback" >"$mutated"
                ;;
            skip-preflight)
                sed '0,/Assert-RecoveryForceReleasePreflight -Contract \$forceReleaseTaskContract/s//Write-Verbose skipped-force-release-preflight/' \
                    "$rollback" >"$mutated"
                ;;
            skip-unregister)
                sed '0,/Unregister-ScheduledTask -TaskPath \$contract.TaskPath/s//Write-Verbose skipped-force-release-task-removal/' \
                    "$rollback" >"$mutated"
                ;;
            unlock-backup)
                sed "0,/Name = 'Backup binary transaction source'/s//Name = 'Unlocked binary source'/" \
                    "$rollback" >"$mutated"
                ;;
            legacy-recovery-disabled)
                sed '0,/-AllowLegacyLogonTrigger:\$allowLegacyCurrentTask/s//-AllowLegacyLogonTrigger:\$false/' \
                    "$rollback" >"$mutated"
                ;;
            legacy-recovery-unbound)
                sed '/^[[:space:]]*\$allowLegacyCurrentTask = ($/,/^[[:space:]]*)$/c\$allowLegacyCurrentTask = $true' \
                    "$rollback" >"$mutated"
                ;;
        esac
        if cmp --silent -- "$rollback" "$mutated"; then
            rm -f -- "$mutated"
            echo "could not construct rollback recovery mutation: $mutation" >&2
            exit 1
        fi
        if rollback_recovery_contract_present "$mutated"; then
            rm -f -- "$mutated"
            echo "rollback checker accepted unsafe recovery mutation: $mutation" >&2
            exit 1
        fi
        rm -f -- "$mutated"
    done
}

require_bootstrap_fixture() {
    local file=$1
    local pattern=$2
    local description=$3
    if ! rg --quiet --multiline --multiline-dotall -- "$pattern" "$file"; then
        echo "Windows bootstrap fixture missing $description" >&2
        exit 1
    fi
}

line_of() {
    local file=$1
    local literal=$2
    local description=$3
    local lines

    lines=$(rg --line-number --fixed-strings -- "$literal" "$file" |
        cut -d: -f1 || true)
    if [[ -z "$lines" ]]; then
        echo "missing ordering anchor: $description" >&2
        exit 1
    fi
    if [[ $lines == *$'\n'* ]]; then
        echo "ambiguous ordering anchor: $description" >&2
        exit 1
    fi
    printf '%s\n' "$lines"
}

line_of_occurrence() {
    local file=$1
    local literal=$2
    local occurrence=$3
    local description=$4
    local line

    line=$(rg --line-number --fixed-strings -- "$literal" "$file" |
        sed -n "${occurrence}p" | cut -d: -f1 || true)
    if [[ -z "$line" ]]; then
        echo "missing ordering anchor occurrence $occurrence: $description" >&2
        exit 1
    fi
    printf '%s\n' "$line"
}

# These are literal PowerShell variable names, not shell expansions.
require '\$ErrorActionPreference = '\''Continue'\''' \
    'Windows PowerShell 5.1 native-stderr protection'
require '\$exitCode = 1\s*\$LASTEXITCODE = \$null' \
    'per-attempt native exit-code reset'
require '2>&1 \| ForEach-Object' 'merged native stdout/stderr logging'
require '& \$viewflowExecutable connect' 'synchronous viewflowd invocation'
require '--peer 172\.16\.105\.62:44119' 'Linux peer endpoint'
require '--server-name viewflow-linux' 'TLS server name'
require '--cert \(Join-Path \$identityRoot .peer\.pem.\)' 'peer certificate path'
require '--key \(Join-Path \$identityRoot .peer\.key.\)' 'peer private-key path'
require '--ca \(Join-Path \$identityRoot .ca\.pem.\)' 'CA certificate path'
require '--input-backend native' 'native Windows input backend'
require '--device-id 00000000000000000000000000000002' 'Windows device identity'
require 'while \(\$true\)' 'foreground supervisor loop'
require '\$MaximumAttempts -ne 0.*\$attempt -ge \$MaximumAttempts' \
    'bounded test-attempt exit'
require 'Start-Sleep -Milliseconds \$restartDelayMs' 'restart delay'
require '\[Math\]::Min\(\s*\$MaximumRestartDelayMs' 'restart-delay cap'
require '\$restartDelayMs \* 2' 'exponential restart backoff'
require '\[long\]\[Math\]::Round' 'overflow-safe process runtime accounting'
require '\$ErrorActionPreference = \$savedErrorActionPreference' \
    'ErrorActionPreference restoration'
require 'exit \$exitCode' 'native exit-code propagation at the attempt limit'

continue_line=$(rg --line-number --fixed-strings \
    '$ErrorActionPreference = '\''Continue'\''' "$script" | cut -d: -f1)
invoke_line=$(rg --line-number --fixed-strings \
    '& $viewflowExecutable connect' "$script" | cut -d: -f1)
restore_line=$(rg --line-number --fixed-strings \
    '$ErrorActionPreference = $savedErrorActionPreference' "$script" | cut -d: -f1)
if ((continue_line >= invoke_line || invoke_line >= restore_line)); then
    echo 'native invocation is outside its PowerShell 5.1 stderr guard' >&2
    exit 1
fi

if rg --quiet 'Start-Process|start-process' "$script"; then
    echo 'wrapper must keep viewflowd synchronous; Start-Process is forbidden' >&2
    exit 1
fi

require_installer '\[string\]\$BootstrapRequestPath.*BootstrapRequestPath must be the only explicit installer argument.*\$requestKeys = @\(.*marker_handoff_receipt_path.*linux_frozen_evidence_path.*prepared_receipt_path.*mutation_permit_path.*force_release_envelope_path.*linux_stage_receipt_path.*installer_exit_receipt_path.*viewflow-windows-bootstrap-requested' \
    'request-only strict bootstrap contract'
require_installer '\$fixedRequestLeaves = \[ordered\]@\{.*marker-handoff-receipt\.json.*bootstrap-prepared\.json.*mutation-permit\.json.*force-release-envelope\.json.*linux-stage-receipt\.json.*windows-install-success\.json.*installer-exit\.json.*recovery-force-release\.json.*Bootstrap request path is not fixed' \
    'fixed operation-root bootstrap paths'
require_installer 'Bootstrap request must be owner-only with one FullControl rule.*Bootstrap request input is not owner-only' \
    'owner-only request and reviewed input files'
require_installer 'function Stop-ViewflowTaskAndWait' \
    'shared stop-and-wait helper'
require_installer 'Assert-QuiescedMarker.*-InstalledSha256 \$oldBinaryHash.*-InstalledWrapperSha256 \$oldScriptHash.*-CandidateSha256 \$candidateHash' \
    'installed binary, installed wrapper, and candidate-bound marker validation'
require_installer '\[switch\]\$AllowV13Bootstrap.*function Assert-V13BootstrapEvidence.*\$Marker\.schema_version -ne 1.*viewflow-v13-bootstrap-frozen.*Bootstrap evidence schema, state, or operation_id is invalid' \
    'explicit independent strict v1.3 bootstrap branch'
require_installer '\$marker\.schema_version -isnot \[int\].*\$marker\.schema_version -ne 4.*\$marker\.state -isnot \[string\].*\$marker\.state -cne .viewflow-input-quiesced.' \
    'strict schema-4 quiesced-marker schema'
if ! exact_property_set_contract_present "$installer"; then
    echo 'installer missing case-sensitive exact JSON property-set validation' >&2
    exit 1
fi
run_exact_property_set_weakening_mutation
require_installer 'release_all_applied.*route_revoked.*peer_disconnected.*confirmation_source.*forbidden legacy assertion' \
    'legacy operator assertion rejection'
require_installer '\$marker\.peer -isnot \[string\].*\$marker\.peer -cne \$expectedPeer.*\$marker\.device_id -isnot \[string\].*\$marker\.device_id -cne \$expectedDeviceId' \
    'peer and Windows device marker validation'
require_installer '\$marker\.operation_id -isnot \[string\].*A-Za-z0-9_.*\$marker\.daemon_pid.*Test-JsonInteger.*\$marker\.daemon_start_ticks.*\$marker\.boot_id.*expectedDaemonInstanceId' \
    'operation and daemon-instance identity validation'
require_installer '\$marker\.protocol_version -isnot \[string\].*2\.1.*\$marker\.local_device.*\$expectedLocalDeviceId.*\$marker\.target_device.*\$expectedDeviceId' \
    'protocol and Linux-to-Windows device binding'
require_installer '\$cleanup\.route_ever_activated -isnot \[bool\].*\$cleanup\.route_was_active -isnot \[bool\].*not_required_no_active_route.*route_ever_activated -ne \$true.*release_all\.status.*applied.*lease_revoke\.status.*applied' \
    'strict two-branch daemon cleanup evidence validation'
require_installer 'Assert-ExactPropertySet -Value \$cleanup.*source_display.*route_generation.*\$null -ne \$cleanup\.source_display.*\$null -ne \$cleanup\.route_generation.*\$cleanup\.source_display -cne \$expectedSourceDisplayId.*\$cleanup\.route_generation -gt \$maximumJsonInteger' \
    'exact schema-4 source-display and route-generation cleanup binding'
for fixture_case in \
    top-state-case-only \
    source-display-case-only \
    source-display-null-active \
    route-generation-case-only \
    route-generation-null-active \
    route-generation-string \
    route-generation-double \
    route-generation-over-uint53; do
    if ! rg --quiet --fixed-strings "'$fixture_case'" "$marker_test"; then
        echo "marker fixture missing case: $fixture_case" >&2
        exit 1
    fi
done
require_installer '\$ack\.event_sequence.*\$cleanup\.last_input_sequence \+ 1.*lease_revoke\.generation.*active_lease_generation \+ 1.*\$revokeAck\.operation_id.*\$revokeAck\.lease_generation.*\$revokeAck\.owner_device.*\$revokeAck\.target_device.*\$revokeAck\.state.*revoked.*\$revokeAck\.result.*applied' \
    'exact ReleaseAll and LeaseRevoke Applied ACK validation'
require_installer '172\\\.16\\\.105\\\.70.*port.*65535' \
    'bound Windows peer socket validation'
if rg --quiet 'not_required_no_bound_peer' "$installer"; then
    echo 'installer must reject activated cleanup without exact bound-peer evidence' >&2
    exit 1
fi
require_installer '\$marker\.peer_disconnect_status -isnot \[string\].*confirmed_by_daemon_exit.*\$exitEvidence\.operation_id.*\$marker\.operation_id.*sidecar_socket_present -isnot \[bool\].*observation_sha256' \
    'bound Linux daemon-exit evidence validation'
require_installer 'completed_at_unix_ms.*observed_at_unix_ms.*daemon-exit evidence predates' \
    'fresh ordered daemon cleanup and exit timestamps'
require_installer 'linux_viewflowd.*linux_peer_certificate.*linux_peer_private_key.*linux_certificate_authority.*windows_installed_viewflowd.*windows_candidate_viewflowd.*windows_client_wrapper.*windows_peer_certificate.*windows_peer_private_key.*windows_certificate_authority' \
    'frozen ten-artifact hash set'
require_installer 'windows_installed_viewflowd.*InstalledSha256.*windows_candidate_viewflowd.*CandidateSha256.*windows_client_wrapper.*InstalledWrapperSha256' \
    'Windows binary and wrapper artifact bindings'
require_installer '\$marker\.created_utc -isnot \[string\].*DateTimeOffset.*\$createdAge\.TotalSeconds -lt -30.*\$createdAge\.TotalSeconds -gt \$QuiescedMarkerMaxAgeSeconds' \
    'strict fresh created_utc validation'
require_installer '\$authorization = Assert-QuiescedMarker.*\$operationId = \[string\]\$authorization\.OperationId' \
    'consumed quiescence authorization object and operation binding'
require_installer 'function Move-ConsumedEvidence.*\.consumed\.\{1\}.*\[IO\.File\]::Move\(\$fullPath, \$consumed\)' \
    'same-directory operation-scoped atomic evidence consumption'
require_installer '\$linuxEvidenceSha256 = \[string\]\$authorization\.Sha256.*\$consumedEvidence = Move-ConsumedEvidence -Path \$QuiescedMarkerPath.*-OperationId \$operationId' \
    'snapshot-hash-bound one-shot quiesced/bootstrap evidence consumption'
require_installer '\$consumedAuthorization = Assert-QuiescedMarker -Path \$consumedEvidence.*-AllowBootstrap:\$AllowV13Bootstrap.*\$consumedAuthorization\.OperationId -cne \$operationId.*\$consumedAuthorization\.Sha256 -cne \$linuxEvidenceSha256' \
    'consumed evidence operation and snapshot-hash revalidation'
if rg --quiet --fixed-strings \
    'Remove-Item -LiteralPath $QuiescedMarkerPath' "$installer"; then
    echo 'installer must retain evidence under its operation-scoped consumed name' >&2
    exit 1
fi
require_installer '\[string\]\$RollbackManifestPath.*\[string\]\$RollbackTokenPath.*\[string\]\$RecoveryBundlePath.*\[string\]\$RuntimeReceiptPath.*\[string\]\$DaemonExitEvidencePath.*\[string\]\$DaemonExitObservationPath.*\[string\]\$RecoveryForceReleaseReceiptPath' \
    'request-derived rollback outputs and normal-v2 evidence parameters'
require_installer '\$commonOutputPaths = @\(.*\$ReadinessReceiptPath.*\$ReadinessLockPath.*\$ReadinessCommitRequestPath.*\$InstallSuccessReceiptPath.*\$RollbackManifestPath.*\$RollbackTokenPath.*\$RecoveryBundlePath.*\$RecoveryForceReleaseReceiptPath.*\$RuntimeReceiptPath.*\$DaemonExitEvidencePath.*\$DaemonExitObservationPath' \
    'pairwise-distinct common outputs and normal evidence paths'
require_installer 'if \(\$AllowV13Bootstrap\).*Normal daemon-exit evidence paths are forbidden for bootstrap install.*\$ForceReleaseReceiptPath.*\$LinuxDeactivationProofPath.*\$LinuxDeactivationTranscriptPath' \
    'bootstrap-only output union without daemon observation'
require_installer 'Bootstrap-only force-release and deactivation paths are forbidden for normal install.*Normal rollback evidence paths must be existing absolute files.*Assert-OwnerOnlyFileSecurity.*\$RuntimeReceiptPath, \$DaemonExitEvidencePath, \$DaemonExitObservationPath' \
    'normal-v2 exact evidence union and private input validation'
require_installer '\$bootstrapTaskName = .Viewflow Bootstrap Force Release \{0\}.*\$OperationId' \
    'operation-specific bootstrap force-release task name'
require_installer '\$bootstrapTaskDispatchDeadlineSeconds = 120.*\$bootstrapTaskExecutionDeadlineSeconds = 30.*function Get-BootstrapForceReleaseMonotonicSeconds.*ExecutionTimeLimit.*bootstrapTaskExecutionDeadlineSeconds.*\$dispatchStartedSeconds = Get-BootstrapForceReleaseMonotonicSeconds.*\$executionStartedSeconds = \$null.*\$executionStartedSeconds = \$nowSeconds.*-DispatchElapsedSeconds \(\$nowSeconds - \$dispatchStartedSeconds\).*-ExecutionElapsedSeconds.*\$nowSeconds - \$executionStartedSeconds' \
    'separate bootstrap dispatch and execution deadlines'
if ! bootstrap_force_release_deadline_contract_present "$installer"; then
    echo 'installer missing bootstrap force-release monotonic deadline binding' >&2
    exit 1
fi
run_bootstrap_force_release_deadline_mutation
require_installer 'function Get-BootstrapForceReleaseAttemptEvidencePath.*force-release-attempt[.]json.*function Get-BootstrapForceReleaseAttemptSnapshot.*last_task_result.*last_run_time_utc.*observed_pid.*observed_process_start_filetime.*receipt_exists.*function Write-BootstrapForceReleaseAttemptEvidence.*Write-OwnerOnlyCreateOnceJson' \
    'create-once owner-only bootstrap force-release attempt evidence'
require_installer 'Get-BootstrapForceReleaseAttemptSnapshot.*before stop/unregister.*Stop-ScheduledTask.*Unregister-ScheduledTask.*cleanupFailures.*attempt evidence publication.*InvalidOperationException.*primaryFailure\.Exception' \
    'pre-cleanup attempt snapshot and chained fail-closed cleanup'
if ! bootstrap_force_release_task_contract_present "$installer"; then
    echo 'installer missing bootstrap force-release no-clobber or recorded-identity contract' >&2
    exit 1
fi
run_bootstrap_force_release_task_mutations
require_installer 'function Invoke-BootstrapForceRelease.*force-release-input --receipt.*Assert-ForceReleaseReceipt' \
    'interactive bootstrap force-release task and strict receipt gate'
if ! force_release_observed_identity_contract_present "$installer"; then
    echo 'installer missing force-release observed PID/FILETIME receipt binding' >&2
    exit 1
fi
run_force_release_observed_identity_mutation
require_installer 'function Invoke-BootstrapForceRelease.*try \{.*Register-ScheduledTask.*\} finally \{.*Unregister-ScheduledTask.*\$remainingBootstrapTask = Get-ScheduledTask.*-ErrorAction SilentlyContinue.*\$null -ne \$remainingBootstrapTask.*could not be removed' \
    'success-and-failure bootstrap temporary-task removal postcondition'
require_installer 'if \(\$AllowV13Bootstrap\).*\$forceReceipt = Invoke-BootstrapForceRelease -Candidate \$CandidatePath.*-OperationId \$operationId.*-LinuxEvidenceSha256 \$linuxEvidenceSha256' \
    'main-flow force-release invocation bound to bootstrap authorization'
require_installer 'function Write-BootstrapRecoveryPreparedReceipt.*mutation_permit_path.*force_release_envelope_path.*linux_stage_receipt_path.*install_success_receipt_path.*installer_exit_receipt_path.*viewflow-windows-bootstrap-recovery-armed.*bootstrap_request_sha256.*marker_handoff_receipt.*rollback_authorization.*old_task.*old_executable.*Write-OwnerOnlyCreateOnceJson' \
    'owner-only create-once bootstrap recovery prepared receipt'
require_installer 'function Wait-BootstrapMutationPermit.*viewflow-windows-bootstrap-mutation-permitted.*permit_nonce.*bootstrap_request_sha256.*marker_handoff_receipt_sha256.*windows_prepared_receipt_sha256.*linux_frozen_evidence_sha256.*linux_viewflowd_sha256.*linux_deployment_marker_sha256.*linux_viewflow_unit_sha256.*Assert-FreshUtcTimestamp' \
    'strict owner-only mutation permit contract'
require_installer '\$bootstrapMutationPermitted = \$false.*\$bootstrapMutationPermit = Wait-BootstrapMutationPermit.*\$bootstrapMutationPermitted = \$true.*-not \(\$AllowV13Bootstrap -and \$bootstrapRecoveryPrepared -and.*\$bootstrapMutationPermitted\)' \
    'no-stop failure path until a mutation permit was validated'
require_installer '\$preMutationBinding.*BootstrapRecoveryPreparedReceiptPath.*BootstrapMutationPermitPath.*Read-OwnerOnlyUtf8JsonSnapshot.*changed before mutation.*Assert-PinnedBootstrapRequestCurrent.*Pinned marker handoff receipt revalidation.*Move-ConsumedEvidence' \
    'P/permit/request/H revalidation immediately before mutation'
require_installer 'function Write-BootstrapForceReleaseEnvelope.*viewflow-windows-bootstrap-force-release-attested.*bootstrap_request_sha256.*marker_handoff_receipt_sha256.*windows_prepared_receipt_sha256.*mutation_permit_sha256.*raw_force_release_receipt_sha256.*Write-OwnerOnlyCreateOnceJson' \
    'create-once force-release envelope chain binding'
require_installer 'function Wait-BootstrapLinuxStageReceipt.*viewflow-linux-bootstrap-staged.*evidence_hashes.*artifact_hashes.*staged_viewflowd.*MutationPermit\.linux_viewflowd_sha256.*staged_deployment_marker_tool.*MutationPermit\.linux_deployment_marker_sha256.*staged_viewflow_unit.*MutationPermit\.linux_viewflow_unit_sha256.*runtime_marker_present.*authenticated_peer_ip.*172\.16\.105\.70' \
    'exact Linux stage receipt and permit candidate equality'
require_installer 'function Start-ViewflowTaskAndWait.*Start-ScheduledTask.*Wait-BootstrapLinuxStageReceipt.*\$wait = \[Diagnostics\.Stopwatch\]::StartNew\(\)' \
    'Ls-before-readiness timer ordering'
require_installer '\$readinessWaitSeconds = if \(\$AllowV13Bootstrap\) \{ 120 \} else \{ 180 \}.*\$commitWaitSeconds = if \(\$AllowV13Bootstrap\) \{ 120 \} else \{ 30 \}' \
    'bootstrap 120-second readiness and commit budgets'
require_installer 'function New-RollbackAuthorization.*\$RollbackMode.*viewflow-windows-rollback-authorized.*rollback_mode = \$RollbackMode.*Write-OwnerOnlyCreateOnceJson' \
    'create-once owner-only mode-bound rollback authorization token'
require_installer 'function Write-RollbackManifest.*\$RollbackMode.*viewflow-windows-rollback-armed.*rollback_mode = \$RollbackMode.*linux_deactivation_proof_path.*linux_deactivation_transcript_path.*runtime_receipt_path.*daemon_exit_evidence_path.*daemon_exit_observation_path.*Write-OwnerOnlyCreateOnceJson' \
    'exact discriminated rollback manifest union'
require_installer 'New-RollbackAuthorization -OperationId \$operationId.*-RollbackMode \$rollbackMode.*Write-RollbackManifest -Path \$RollbackManifestPath.*-RollbackMode \$rollbackMode' \
    'all-mode rollback token and manifest publication'
require_installer 'function Write-ReadinessCommitRequest.*\$bootstrapOnlyHashes = @\(.*\$ForceReceiptSha256.*\$MarkerHandoffReceiptSha256.*\$WindowsPreparedReceiptSha256.*\$MutationPermitSha256.*\$LinuxStageReceiptSha256.*\$BootstrapRequestSha256.*pairwise distinct.*Normal readiness commit request must use null bootstrap hashes.*schema_version = 5.*viewflow-install-commit-request.*marker_handoff_receipt_sha256.*windows_prepared_receipt_sha256.*mutation_permit_sha256.*linux_stage_receipt_sha256.*bootstrap_request_sha256' \
    'strict readiness-bound schema-5 commit request and six-hash union'
require_installer 'function Write-ReadinessCommitRequest.*\[IO\.FileMode\]::CreateNew.*\[IO\.FileOptions\]::WriteThrough.*Flush\(\$true\).*Assert-AuthenticatedReadinessCommitBoundary.*\[IO\.File\]::Move\(\$temporary, \$Path\).*\$RequestPublished\.Value = \$true' \
    'commit request write-through create-once publication after live guard validation'
require_installer 'function Assert-DaemonInstallSuccessReceipt.*Daemon-authored install-success receipt.*commit_nonce.*commit_request_sha256.*commit_mode.*committed_by_daemon.*readiness_connection_generation.*new_process_user_sid.*committed_at_utc.*\$Receipt\.commit_nonce -cne \[string\]\$CommitRequest\.Nonce.*\$Receipt\.commit_request_sha256 -cne \[string\]\$CommitRequest\.Sha256.*\$Receipt\.commit_mode -cne \[string\]\$CommitRequest\.Mode.*-not \[bool\]\$Receipt\.committed_by_daemon' \
    'exact daemon-authored schema-5 commit receipt validation'
require_installer 'function Wait-DaemonInstallSuccessReceipt.*\$InstallCommitted\.Value = \$true.*Read-OwnerOnlyUtf8JsonSnapshot -Path \$Path.*Assert-DaemonInstallSuccessReceipt.*Assert-AuthenticatedReadinessCommitBoundary.*\$commitWaitSeconds' \
    'bounded daemon receipt wait with live readiness and irreversible receipt detection'
if rg --quiet '^function Write-InstallSuccessReceipt' "$installer"; then
    echo 'installer must not author the install-success receipt' >&2
    exit 1
fi
require_installer '\$forceReceiptRead = Assert-ForceReleaseReceipt.*\$forceReceiptHash = \[string\]\$forceReceiptRead\.Sha256.*Write-ReadinessCommitRequest.*-ForceReceiptSha256 \$forceReceiptHash.*-MarkerHandoffReceiptSha256 \$markerHandoffCommitHash.*-WindowsPreparedReceiptSha256 \$preparedCommitHash.*-MutationPermitSha256 \$mutationPermitCommitHash.*-LinuxStageReceiptSha256 \$linuxStageCommitHash.*-BootstrapRequestSha256 \$bootstrapRequestCommitHash.*Wait-DaemonInstallSuccessReceipt.*-ForceReceiptSha256 \$forceReceiptHash.*-MarkerHandoffReceiptSha256 \$markerHandoffCommitHash.*-WindowsPreparedReceiptSha256 \$preparedCommitHash.*-MutationPermitSha256 \$mutationPermitCommitHash.*-LinuxStageReceiptSha256 \$linuxStageCommitHash.*-BootstrapRequestSha256 \$bootstrapRequestCommitHash' \
    'mode-aware six-hash bootstrap chain through request and daemon receipt'
require_installer '\$actions\.Count -ne 1' 'single scheduled-task action validation'
require_installer '\$expectedPowerShell = \[System\.IO\.Path\]::GetFullPath\(.*System32\\WindowsPowerShell\\v1\.0\\powershell\.exe' \
    'exact Windows PowerShell task-action path'
require_installer 'IsPathRooted\(\[string\]\$actions\[0\]\.Execute\).*\$actionExecutable\.Equals\(.*\$expectedPowerShell' \
    'rooted exact task-action executable validation'
if ! task_action_parser_contract_present "$installer"; then
    echo 'installer missing exact tokenized task-action argument validation' >&2
    exit 1
fi
run_task_action_parser_weakening_mutation
require_installer 'Principal\.LogonType -ne .Interactive.' \
    'interactive scheduled-task principal validation'
require_installer 'Principal\.UserId.*New-Object -TypeName System\.Security\.Principal\.NTAccount.*-ArgumentList \$taskUserId.*\$taskUserSid -ne \$expectedTaskUserSid' \
    'scheduled-task principal UserId validation'
require_installer 'Principal\.RunLevel -ne .Limited.' \
    'limited scheduled-task principal validation'
require_installer '\$runLevel = @\(\$principalNodes\[0\]\.SelectNodes\(.t:RunLevel..*\$runLevel\.Count -gt 1.*\$runLevel\.Count -eq 1 -and \[string\]\$runLevel\[0\]\.InnerText -cne .LeastPrivilege.' \
    'default-omitted or explicit LeastPrivilege task XML run level'
require_installer 'MultipleInstancesPolicy = .IgnoreNew' \
    'Task Scheduler XML MultipleInstancesPolicy validation'
require_installer 'optionalTrueSetting in @\(' \
    'optional Task Scheduler XML true settings validation'
require_installer 'Settings\.Enabled' 'enabled scheduled-task validation'
require_installer 'Settings\.DisallowStartIfOnBatteries' \
    'start-on-battery scheduled-task validation'
require_installer 'Settings\.StopIfGoingOnBatteries' \
    'continue-on-battery scheduled-task validation'
require_installer '\$executionTimeLimit -ne .PT0S..*\$executionTimeLimit -ne \[TimeSpan\]::Zero\.ToString\(\)' \
    'unlimited scheduled-task execution-time validation'
require_installer 'Settings\.RestartCount -ne 0' \
    'disabled Task Scheduler restart policy validation'
require_installer 'Settings\.AllowHardTerminate.*Convert.*ToBoolean\(\$Task\.Settings\.AllowHardTerminate\)' \
    'Task Scheduler termination permission validation'
require_installer '\$Process\.SessionId -ne 1' 'interactive Session 1 validation'
require_installer 'connect.*--peer \$expectedPeer.*--server-name \$expectedServerName.*--input-backend native.*--device-id \$expectedDeviceId' \
    'running process command-line validation'
require_installer '.--cert. = \$expectedCert.*.--key. = \$expectedKey.*.--ca. = \$expectedCa' \
    'running process certificate, key, and CA path validation'
require_installer 'Assert-ExpectedWrapperConfiguration -Path \$sourceScript' \
    'source wrapper configuration validation'
require_installer 'function Assert-ExpectedIdentityMaterial.*BEGIN CERTIFICATE.*BEGIN \(\?<label>\(\?:RSA \|EC \)\?PRIVATE KEY\).*Test-Path -LiteralPath \$identity\.Path -PathType Leaf.*\$file\.Length -eq 0.*FromBase64String.*X509Certificate2' \
    'non-empty parseable PEM identity material validation'
require_installer '\$requiredFragments = @\(.*--cert \(Join-Path \$identityRoot.*peer\.pem.*--key \(Join-Path \$identityRoot.*peer\.key.*--ca \(Join-Path \$identityRoot.*ca\.pem' \
    'reviewed wrapper certificate, key, and CA arguments'
require_installer 'Assert-ExpectedIdentityMaterial\s*\$task = Get-ScheduledTask' \
    'identity validation before task stop or file replacement'
require_installer 'function Assert-LegacyOrNoTaskTriggers.*\$taskTriggers = @\(\$Task\.Triggers \| Where-Object \{ \$null -ne \$_ \}\).*\$taskTriggers\.Count -eq 0.*-not \$AllowLegacyLogonTrigger -or \$taskTriggers\.Count -ne 1.*MSFT_TaskLogonTrigger.*enabledProperty\.Value -isnot \[bool\].*Resolve-LegacyLogonTriggerSid.*\$expectedTaskUserSid' \
    'PS5.1 null-safe exact legacy LogonTrigger object validation'
require_installer 'function Assert-LegacyOrNoTaskXmlTriggers.*SelectNodes\(.*/t:Task/t:Triggers.*\$containers\.Count -ne 1.*\$triggers\.Count -eq 0.*-not \$AllowLegacyLogonTrigger -or \$triggers\.Count -ne 1.*LogonTrigger.*Attributes\.Count -ne 0.*\$userNodes\.Count -ne 1.*\$enabledNodes\.Count -gt 1.*\$children\.Count -ne \(1 \+ \$enabledNodes\.Count\).*InnerText -cne .true..*Resolve-LegacyLogonTriggerSid.*\$expectedTaskUserSid' \
    'exact legacy LogonTrigger XML validation'
require_installer 'function Assert-ExpectedScheduledTask.*Assert-UpdatableScheduledTask -Task \$Task -RequireRunning:\$RequireRunning' \
    'strict trigger-free normalized task validation'
require_installer 'Assert-UpdatableScheduledTask -Task \$task -RequireRunning.*-AllowLegacyLogonTrigger.*Assert-TaskXmlContract -Xml \$oldTaskXml -AllowLegacyLogonTrigger.*Assert-UpdatableScheduledTask -Task \$prePublishTask -RequireRunning.*-AllowLegacyLogonTrigger' \
    'legacy-trigger compatibility limited to pre-update task and backup XML'
require_installer 'Assert-ExpectedScheduledTask -Task \$enabledTask -RequireReady.*Assert-ExpectedScheduledTask -Task \$startedTask -RequireRunning.*Assert-TaskXmlContract -Xml \$newTaskXml -RequireCurrentReadinessBinding' \
    'strict trigger-free post-registration and commit task validation'
require_installer 'Assert-UpdatableScheduledTask -Task \$restoredTask.*-AllowLegacyLogonTrigger.*Assert-TaskXmlContract -Xml \$restoredTaskXml.*-AllowLegacyLogonTrigger.*\$restoredTaskXmlHash -cne \$oldTaskXmlHash' \
    'legacy restored-task compatibility with exact backup XML hash binding'
require_installer '\$nonNullBootstrapOnlyHashes = @\(.*\$bootstrapOnlyHashes \| Where-Object \{ \$null -ne \$_ \}.*\).*\$nonNullBootstrapOnlyHashes\.Count -ne 0' \
    'PS5.1 null-safe bootstrap hash validation'
require_installer '\$candidateHash -cne \$expectedCandidateHash' \
    'candidate binary hash validation'
require_installer '\$installedHash -cne \$candidateHash' \
    'installed binary hash validation'
require_installer '\$installedScriptHash -cne \$sourceScriptHash' \
    'installed wrapper hash validation'
require_installer 'Get-FileSha256Lower -Path \$installedBinary\) -cne \$oldBinaryHash.*Get-FileSha256Lower -Path \$installedScript\) -cne \$oldScriptHash' \
    'rollback file hash validation'
require_installer 'Viewflow install failed: \{0\}; automatic rollback failed: \{1\}.*-f @\(' \
    'PowerShell 5.1-safe rollback error construction'
require_installer '\$stopStableObservationMs = 6000' \
    'stop stability interval longer than the supervisor restart cap'
require_installer '\$task = Get-ScheduledTask.*\$inactiveTaskState = \$task\.State -eq .Ready. -or.*\$AllowDisabled -and \$task\.State -eq .Disabled..*\$running\.Count -eq 0 -and \$inactiveTaskState.*\$stableSinceMs = \$null' \
    'stable Ready task and zero-process stop observation with explicit disabled opt-in'
require_installer '\$wait\.ElapsedMilliseconds -lt 20000' \
    'bounded stable-stop observation'
require_installer '\$startStableObservationMs = 6000' \
    'stable-start observation interval'
require_installer 'function Assert-AuthenticatedReadiness.*\[string\]\$ReceiptPath.*\[string\]\$LockPath.*\[string\]\$OperationId.*\[string\]\$DaemonSha256.*\$ProcessIdentity' \
    'authenticated-readiness verifier inputs'
require_installer 'function Assert-AuthenticatedReadiness.*Read-OwnerOnlyUtf8JsonSnapshot -Path \$ReceiptPath.*viewflow-post-mtls-readiness-established.*while-readiness-lock-is-held.*\$receipt\.operation_id -cne \$OperationId' \
    'owner-only readiness receipt with operation and live-lock validity binding'
require_installer '\$receipt\.daemon_executable_sha256 -cne \$DaemonSha256.*\$receipt\.daemon_pid.*\$ProcessIdentity\.ProcessId' \
    'readiness receipt candidate hash and exact daemon PID'
require_installer '\$receipt\.daemon_process_start_filetime -isnot \[string\].*\$receipt\.daemon_process_start_filetime -cne \$processStart' \
    'readiness receipt process-start identity'
require_installer '\$receipt\.daemon_session_id.*-ne 1.*\$receipt\.daemon_user_sid.*-cne \$processSid.*\$processSid -cne \$expectedTaskUserSid' \
    'readiness receipt interactive session and task-user identity'
require_installer '\$receipt\.protocol_major.*-ne 2.*\$receipt\.protocol_minor.*-ne 1.*probe_round_trip_ns.*probe_max_round_trip_ns.*33333334.*probe_uncertainty_ns.*probe_max_uncertainty_ns.*4000000' \
    'authenticated protocol 2.1 and two-frame probe bounds'
require_installer 'function Open-PinnedReadinessLockSnapshot.*Assert-OwnerOnlyFileSecurity -Path \$Path.*\[IO\.File\]::Open\(.*\[IO\.FileShare\]::ReadWrite.*Read-Utf8JsonStreamSnapshot -Stream \$stream.*Stream = \$stream.*Sha256 = \$snapshot\.Sha256' \
    'owner-only pinned readiness lock snapshot'
require_installer 'Open-PinnedReadinessReceiptSnapshot -Path \$ReceiptPath.*Open-PinnedReadinessLockSnapshot -Path \$LockPath.*\$lockRead\.Sha256 -cne.*\$receipt\.readiness_lock_sha256' \
    'pinned readiness receipt and lock hash binding'
require_installer '\$lock\.operation_id -cne \$OperationId.*\$lock\.daemon_pid.*\$ProcessIdentity\.ProcessId' \
    'readiness lock operation and exact daemon PID binding'
require_installer '\$lock\.daemon_process_start_filetime -cne \$processStart.*\$lock\.connection_generation.*\$receipt\.connection_generation' \
    'readiness lock process-start and connection-generation binding'
require_installer 'Assert-ReadinessLockIsLive -Path \$LockPath' \
    'readiness lock live-handle verification'
require_installer 'Read-Utf8JsonStreamSnapshot.*-Stream \$pinnedReceipt\.Stream.*Read-Utf8JsonStreamSnapshot.*-Stream \$pinnedLock\.Stream.*\$receiptReadAgain\.Sha256 -cne \[string\]\$receiptRead\.Sha256.*\$lockReadAgain\.Sha256 -cne \[string\]\$lockRead\.Sha256.*Assert-ViewflowProcessIdentityCurrent -Identity \$ProcessIdentity.*Assert-ReadinessLockIsLive -Path \$LockPath' \
    'same-handle readiness artifact and process revalidation'
require_installer 'function Assert-AuthenticatedReadinessCommitBoundary.*\$Readiness\.ReceiptStream.*\$Readiness\.LockStream.*Read-Utf8JsonStreamSnapshot.*-Stream \$Readiness\.ReceiptStream.*Read-Utf8JsonStreamSnapshot.*-Stream \$Readiness\.LockStream.*Assert-ViewflowProcessIdentityCurrent.*Assert-ExpectedScheduledTask -Task \$task -RequireRunning.*Assert-TaskXmlContract -Xml \$taskXml -RequireCurrentReadinessBinding.*\$taskXmlSha256 -cne \$ExpectedTaskXmlSha256.*Assert-ReadinessLockIsLive' \
    'dual-pinned readiness commit-boundary revalidation'
require_installer 'function Close-AuthenticatedReadinessLease.*ReceiptStream.*LockStream.*\$property\.Value = \$null.*try \{.*\$stream\.Dispose\(\).*catch.*\$closeFailures\.Add.*if \(\$closeFailures\.Count -gt 0\).*AggregateException.*Close-AuthenticatedReadinessLease -Readiness \$readinessLease' \
    'aggregate two-handle readiness cleanup on success and failure'
require_installer '\[ref\]\$RequestPublished.*\[IO\.File\]::Move\(\$temporary, \$Path\)\s*\$RequestPublished\.Value = \$true.*\$InstallCommitted\.Value = \$true.*\$commitRequestPublished = \$false.*-RequestPublished \(\[ref\]\$commitRequestPublished\).*if \(\$installCommitted -or.*\$commitRequestPublished.*automatic rollback was not attempted' \
    'request publication and daemon receipt commit states that forbid unsafe rollback'
require_installer 'function Assert-ReadinessLockIsLive.*\[IO\.File\]::Open\(.*\[IO\.FileAccess\]::ReadWrite.*\[IO\.FileShare\]::Read.*\$win32Error -eq 32.*Readiness lock is not held by the running daemon' \
    'readiness lock sharing-violation liveness proof'
require_installer 'function Start-ViewflowTaskAndWait.*\[string\]\$OperationId.*\[string\]\$ReadinessReceiptPath.*\[string\]\$ReadinessLockPath.*\[string\]\$ExpectedDaemonSha256.*\$task\.State -eq .Running. -and \$running\.Count -eq 1.*Get-ViewflowProcessIdentity -Process \$running\[0\].*\$identityKey = .\{0\}:\{1\}..*\$identity\.ProcessId.*\$identity\.ProcessStartFileTime.*\$stableProcessIdentityKey -cne \$identityKey.*\$stableSinceMs = \$wait\.ElapsedMilliseconds.*\$wait\.ElapsedMilliseconds - \$stableSinceMs.*\$startStableObservationMs.*Test-Path -LiteralPath \$ReadinessReceiptPath.*Test-Path -LiteralPath \$ReadinessLockPath.*Assert-AuthenticatedReadiness.*-OperationId \$OperationId.*-DaemonSha256 \$ExpectedDaemonSha256.*-ProcessIdentity \$stableProcessIdentity.*\$finalTask\.State -ne .Running..*Assert-ViewflowProcessIdentityCurrent.*-Identity \$stableProcessIdentity.*\$wait\.Elapsed\.TotalSeconds -lt \$readinessWaitSeconds' \
    'six-second same-process-identity running-task authenticated-readiness gate'
require_installer 'Register-ExpectedScheduledTask -PreviousTask \$task.*-OperationId \$operationId.*-ReadinessReceiptPath \$ReadinessReceiptPath.*-ReadinessLockPath \$ReadinessLockPath.*Start-ViewflowTaskAndWait -OperationId \$operationId.*-ReadinessReceiptPath \$ReadinessReceiptPath.*-ReadinessLockPath \$ReadinessLockPath.*-ExpectedDaemonSha256 \$candidateHash' \
    'scheduled-task and startup readiness arguments bound to the operation and candidate'
if rg --quiet 'ExpectedProtocolVersion|logLineCountBeforeStart|protocolReady' "$installer"; then
    echo 'installer must use authenticated readiness, not the obsolete protocol-log gate' >&2
    exit 1
fi
require_installer '\$backupTaskXml = Join-Path \$backupRoot .Viewflow-Peer\.xml.*Export-ScheduledTask -TaskPath \$taskPath -TaskName \$taskName' \
    'scheduled-task XML backup'
if ! backup_acl_contract_present "$installer" "$rollback"; then
    echo 'installer or rollback missing pre-permit owner-only backup ACL contract' >&2
    exit 1
fi
run_backup_acl_mutations
require_installer 'function Register-ExpectedScheduledTask.*New-ScheduledTaskAction.*-Execute \$expectedPowerShell.*New-ScheduledTaskPrincipal.*-UserId \(\[string\]\$PreviousTask\.Principal\.UserId\).*-LogonType Interactive.*-RunLevel Limited.*New-ScheduledTaskSettingsSet.*-Disable.*-MultipleInstances IgnoreNew.*-AllowStartIfOnBatteries.*-DontStopIfGoingOnBatteries.*-ExecutionTimeLimit \(\[TimeSpan\]::Zero\).*-RestartCount 0.*Register-ScheduledTask @registration' \
    'disabled exact scheduled-task normalization during artifact replacement'
require_installer 'Assert-ExpectedScheduledTask -Task \$registered -RequireDisabled' \
    'post-registration Disabled containment gate'
require_installer 'Register-ExpectedScheduledTask -PreviousTask \$task.*Replace-FileAtomically -Source \$CandidatePath -Destination \$installedBinary.*Replace-FileAtomically -Source \$sourceScript -Destination \$installedScript' \
    'disabled task normalization before atomic candidate and wrapper replacement'
require_installer '\$installedHash -cne \$candidateHash.*\$installedScriptHash -cne \$sourceScriptHash.*Enable-ScheduledTask.*Assert-ExpectedScheduledTask -Task \$enabledTask -RequireReady.*Start-ViewflowTaskAndWait' \
    'verified artifact hashes before task enable and authenticated startup'
require_installer 'Replace-FileAtomically -Source \$backupBinary -Destination \$installedBinary.*-ExpectedSha256 \$oldBinaryHash.*Replace-FileAtomically -Source \$backupScript -Destination \$installedScript.*-ExpectedSha256 \$oldScriptHash.*Register-ScheduledTask -TaskPath \$taskPath -TaskName \$taskName.*-Xml \$oldTaskXml -Force' \
    'atomically verified old files before scheduled-task XML rollback'
require_installer 'Assert-ExpectedScheduledTask -Task \$startedTask -RequireRunning' \
    'normalized running task postcondition'
require_installer '\$restoredTask\.State -ne .Ready..*Get-ExactInstalledViewflowProcesses\)\.Count -ne 0.*Rollback did not leave the old Viewflow task Ready and inactive' \
    'fail-closed rollback Ready/inactive postcondition'
require_bootstrap_fixture "$bootstrap_prepared_test" \
    'Bootstrap recovery prepare/stop/force/replace/start ordering is unsafe.*Rollback backup copies must become owner-only before hashing and permit validation.*Dangerous live mutation appeared before prepared receipt publication.*Dangerous live mutation appeared before mutation permit validation.*Failure containment could stop Viewflow without a validated permit.*ACL must have inheritance disabled.*Prepared receipt producer returned the wrong SHA-256.*must not be a reparse point.*exactly one explicit access rule' \
    'prepared-before-mutation ordering, reparse, ACL, and hash negatives'
require_bootstrap_fixture "$bootstrap_chain_test" \
    'linux_viewflowd_sha256.*linux_deployment_marker_sha256.*linux_viewflow_unit_sha256.*staged_viewflowd.*staged_deployment_marker_tool.*staged_viewflow_unit.*Linux stage installed or preserved artifact binding is invalid.*must be a lowercase' \
    'permit-to-Ls exact Linux artifact equality and lowercase negatives'
require_bootstrap_fixture "$install_success_schema5_test" \
    'schema_version = 5.*force_release_receipt_sha256.*marker_handoff_receipt_sha256.*windows_prepared_receipt_sha256.*mutation_permit_sha256.*linux_stage_receipt_sha256.*bootstrap_request_sha256.*must be pairwise distinct.*normal-v2' \
    'schema-5 W six-hash bootstrap/normal union'
if ! bootstrap_two_phase_contract_present "$installer"; then
    echo 'installer missing frozen two-phase bootstrap negative-test contract' >&2
    exit 1
fi
run_bootstrap_two_phase_mutations

stop_call_count=$(rg --count --fixed-strings 'Stop-ViewflowTaskAndWait' "$installer")
if ((stop_call_count != 4)); then
    echo 'installer must stable-stop in update, rollback, and post-registration containment paths' >&2
    exit 1
fi

authorization_line=$(line_of "$installer" \
    '$authorization = Assert-QuiescedMarker' 'initial authorization')
rollback_install_line=$(line_of_occurrence "$installer" \
    'Replace-FileAtomically -Source $sourceRollbackScript' 1 \
    'bootstrap reviewed rollback installation')
rollback_token_line=$(line_of_occurrence "$installer" \
    '$token = New-RollbackAuthorization -OperationId $operationId' 1 \
    'bootstrap rollback token publication')
rollback_manifest_line=$(line_of_occurrence "$installer" \
    'Write-RollbackManifest -Path $RollbackManifestPath' 1 \
    'bootstrap rollback manifest publication')
prepared_receipt_line=$(line_of_occurrence "$installer" \
    '$bootstrapRecoveryPreparedReceipt =' 2 \
    'bootstrap prepared receipt publication')
mutation_permit_line=$(line_of "$installer" \
    '$bootstrapMutationPermit = Wait-BootstrapMutationPermit' \
    'bootstrap mutation-permit gate')
marker_consume_line=$(line_of "$installer" \
    '$consumedEvidence = Move-ConsumedEvidence' 'authorization consumption')
consumed_revalidation_line=$(line_of "$installer" \
    '$consumedAuthorization = Assert-QuiescedMarker' 'consumed authorization revalidation')
normal_stop_line=$(line_of_occurrence "$installer" \
    'Stop-ViewflowTaskAndWait' 2 'normal stable stop')
task_export_line=$(line_of "$installer" \
    '$oldTaskXml = Export-ScheduledTask' 'old scheduled-task XML export')
force_release_line=$(line_of "$installer" \
    '$forceReceipt = Invoke-BootstrapForceRelease' 'bootstrap force release')
force_envelope_line=$(line_of_occurrence "$installer" \
    '$bootstrapForceReleaseEnvelope =' 2 'bootstrap force-release envelope')
candidate_copy_line=$(line_of "$installer" \
    'Replace-FileAtomically -Source $CandidatePath -Destination $installedBinary' \
    'atomic candidate replacement')
force_receipt_revalidation_line=$(line_of "$installer" \
    '$forceReceiptRead = Assert-ForceReleaseReceipt' 'force-release receipt revalidation')
linux_stage_line=$(line_of "$installer" \
    '$linuxStageReceipt = $startResult.LinuxStageReceipt' \
    'validated Linux stage receipt')
commit_request_line=$(line_of "$installer" \
    '$commitRequest = Write-ReadinessCommitRequest' \
    'readiness commit-request publication')
success_receipt_wait_line=$(line_of "$installer" \
    '$installSuccessReceipt = Wait-DaemonInstallSuccessReceipt' \
    'daemon install-success receipt wait')
rollback_stop_line=$(line_of_occurrence "$installer" \
    'Stop-ViewflowTaskAndWait -IgnoreStopError' 1 'rollback stable stop')
rollback_copy_line=$(line_of "$installer" \
    'Replace-FileAtomically -Source $backupBinary -Destination $installedBinary' \
    'atomic rollback binary restoration')

if ((authorization_line >= task_export_line ||
    task_export_line >= rollback_install_line ||
    rollback_install_line >= rollback_token_line ||
    rollback_token_line >= rollback_manifest_line ||
    rollback_manifest_line >= prepared_receipt_line ||
    prepared_receipt_line >= mutation_permit_line ||
    mutation_permit_line >= marker_consume_line ||
    marker_consume_line >= consumed_revalidation_line ||
    consumed_revalidation_line >= normal_stop_line ||
    normal_stop_line >= force_release_line ||
    force_release_line >= force_envelope_line ||
    force_envelope_line >= candidate_copy_line ||
    candidate_copy_line >= linux_stage_line ||
    linux_stage_line >= force_receipt_revalidation_line ||
    force_receipt_revalidation_line >= commit_request_line ||
    commit_request_line >= success_receipt_wait_line)); then
    echo 'installer bootstrap transaction ordering is unsafe' >&2
    exit 1
fi
if ((rollback_stop_line >= rollback_copy_line)); then
    echo 'installer rollback must stop/wait before restoring the binary' >&2
    exit 1
fi

task_normalize_line=$(line_of "$installer" \
    'Register-ExpectedScheduledTask -PreviousTask $task' 'task normalization')
if ((task_export_line >= normal_stop_line ||
    normal_stop_line >= task_normalize_line ||
    task_normalize_line >= candidate_copy_line)); then
    echo 'installer must export the task, stable-stop, normalize it, then replace files' >&2
    exit 1
fi

if ! rollback_recovery_contract_present "$rollback"; then
    echo 'rollback tool missing frozen Session-1/PS5.1 recovery contract' >&2
    exit 1
fi
run_rollback_recovery_mutations

if rg --quiet 'Stop-Process|taskkill|Terminate\(' "$installer"; then
    echo 'installer must not force-kill around input quiescence or rollback' >&2
    exit 1
fi

catch_line=$(rg --line-number '^} catch \{' "$installer" | cut -d: -f1)
result_line=$(rg --line-number --fixed-strings '[pscustomobject]@{' "$installer" | tail -n 1 | cut -d: -f1)
if sed -n "${catch_line},${result_line}p" "$installer" |
    rg --quiet 'Start-ViewflowTaskAndWait|Start-ScheduledTask'; then
    echo 'installer failure rollback must not restart Viewflow' >&2
    exit 1
fi

require_rollback '\[Parameter\(Mandatory = \$true\)\].*\$ManifestPath.*\[Parameter\(Mandatory = \$true\)\].*\$TokenPath.*\[switch\]\$ValidateOnly.*\$ReceiptPath' \
    'fixed manifest/token validation and optional receipt CLI'
require_rollback 'viewflow-windows-rollback-armed.*\$manifest\.token_sha256 -cne \$tokenSha256.*viewflow-windows-rollback-authorized' \
    'strict manifest/token authorization binding'
require_installer 'schema_version=3;state=viewflow-linux-deactivated' \
    'schema-3 bootstrap rollback evidence type publication'
require_rollback 'function Assert-LinuxDeactivationProofContract.*\$Proof\.schema_version -isnot \[int\].*\$Proof\.schema_version -ne 3.*deployment_marker_tool =.*viewflow-deployment-marker.*Assert-ExactPropertySet -Value \$Proof\.installed_artifacts.*\$artifact\.sha256.*Assert-LowerSha256' \
    'strict schema-3 six-artifact Linux deactivation proof validation'
require_rollback 'Assert-ExactPropertySet -Value \$Proof\.stopped_runtime.*deployment_marker_tool.*deskflow.*viewflow.*Assert-ExactPropertySet -Value \$Proof\.stopped_runtime\.deployment_marker_tool.*exact_process_count.*\$deploymentMarkerTool\.exact_process_count.*-ne 0' \
    'exact stopped deployment-marker tool proof'
require_rollback "'schema_version=3;state=viewflow-linux-deactivated'" \
    'schema-3 rollback manifest evidence type consumption'
require_rollback '\$proofRead = Read-StrictUtf8JsonObject.*Assert-LinuxDeactivationProofContract -Proof \$proofRead\.Value.*Assert-RecoveryBundleContract.*\$validationResult = \[ordered\]@\{.*if \(\$ValidateOnly\).*\$receipt = \[ordered\]@\{.*linux_deactivation_proof_sha256' \
    'schema-3 proof validation before recovery bundle, ValidateOnly, and completion receipts'
require_rollback 'function Assert-CurrentRollbackBoundary.*\[switch\]\$AllowLegacyLogonTrigger.*\$taskState -cne .Running. -and \$taskState -cne .Ready..*Assert-RestoredScheduledTaskContract -Task \$task.*-RequiredState \$taskState.*-AllowLegacyLogonTrigger:\$AllowLegacyLogonTrigger.*\$taskState -ceq .Ready..*\$processes\.Count -ne 0.*Ready Viewflow task must have zero exact installed processes.*\$processes\.Count -ne 1.*Running Viewflow task must have exactly one installed process.*Assert-ExpectedViewflowProcess -Process \$processes\[0\]' \
    'exact Ready-inactive or Running-single-process pre-rollback boundary'
require_rollback 'function Assert-NoTaskTriggers.*\$taskTriggers = @\(\$Task\.Triggers \| Where-Object \{ \$null -ne \$_ \}\).*\$taskTriggers\.Count -ne 0' \
    'PS5.1 null-safe restored-task trigger validation'
require_rollback 'function Assert-LegacyOrNoTaskTriggers.*\$taskTriggers = @\(\$Task\.Triggers \| Where-Object \{ \$null -ne \$_ \}\).*\$taskTriggers\.Count -eq 0.*\$taskTriggers\.Count -ne 1.*MSFT_TaskLogonTrigger.*enabledProperty\.Value -isnot \[bool\].*Resolve-AccountSid.*\$currentUserSid' \
    'exact legacy restored LogonTrigger object validation'
require_rollback 'function Assert-TaskXmlContract.*\$triggerContainers\.Count -ne 1.*\$triggers\.Count -ne 0.*-not \$AllowLegacyLogonTrigger -or \$triggers\.Count -ne 1.*LogonTrigger.*Attributes\.Count -ne 0.*\$triggerUsers\.Count -ne 1.*\$triggerEnabled\.Count -gt 1.*\$children\.Count -ne \(1 \+ \$triggerEnabled\.Count\).*InnerText -cne .true..*Resolve-AccountSid.*\$currentUserSid' \
    'exact legacy backup LogonTrigger XML validation'
require_rollback '\$runLevel = @\(\$principalNodes\[0\]\.SelectNodes\(.t:RunLevel..*\$runLevel\.Count -gt 1.*\$runLevel\.Count -eq 1 -and.*\$runLevel\[0\]\.InnerText -cne .LeastPrivilege.' \
    'default-omitted or unique explicit LeastPrivilege backup XML run level'
require_rollback 'MultipleInstancesPolicy = .IgnoreNew.*DisallowStartIfOnBatteries = .false.*StopIfGoingOnBatteries = .false.*ExecutionTimeLimit = .PT0S.*\$settingNodes = @\(\$settingsNode\.SelectNodes.*\$settingNodes\.Count -ne 1' \
    'unique required Task Scheduler backup XML settings'
require_rollback 'foreach \(\$optionalTrueSetting in @\(.AllowHardTerminate., .Enabled.\).*\$optionalNodes\.Count -gt 1.*\$optionalNodes\.Count -eq 1.*InnerText -cne .true.' \
    'default-true or unique explicit true backup XML settings'
require_rollback 'SelectSingleNode\(.t:RestartOnFailure..*must not contain a restart-on-failure policy' \
    'forbidden backup XML RestartOnFailure policy'
require_rollback '\$allowLegacyCurrentTask = \(.*\$currentBinarySha256 -ceq \[string\]\$manifest\.backup\.binary_sha256 -and.*\$currentWrapperSha256 -ceq \[string\]\$manifest\.backup\.wrapper_sha256.*\$currentBoundary = Assert-CurrentRollbackBoundary.*-AllowLegacyLogonTrigger:\$allowLegacyCurrentTask' \
    'legacy compatibility gated by the exact restored baseline artifact pair'
require_rollback 'Assert-TaskXmlContract -Xml \$taskXml -AllowLegacyLogonTrigger.*Register-ScheduledTask -TaskPath \$taskPath -TaskName \$taskName.*Stop-ScheduledTask -TaskPath \$taskPath -TaskName \$taskName.*Wait-ReadyInactiveBoundary.*Assert-RestoredScheduledTaskContract -Task \$restoredTask.*-AllowLegacyLogonTrigger.*\$restoredTaskXmlSha256 -cne \[string\]\$manifest\.backup\.task_xml_sha256' \
    'legacy backup/restore compatibility with Ready-inactive and exact XML hash binding'
require_rollback '\$stableObservationMs = 6000' \
    'six-second fail-closed stability interval'
require_rollback 'function Wait-ReadyInactiveBoundary.*State.*Ready.*\$processes\.Count -eq 0.*\$stableObservationMs' \
    'stable Ready/inactive containment boundary'
require_rollback 'function Get-RecoveryForceReleaseTaskContract.*Viewflow Rollback Force Release.*function Assert-RecoveryForceReleaseTask.*Interactive.*Limited.*Assert-NoTaskTriggers.*PT30S.*function Assert-RecoveryForceReleaseTaskXml.*InteractiveToken.*LeastPrivilege.*ExecutionTimeLimit.*PT30S.*RestartOnFailure' \
    'strict trigger-free current-user Session-1 force-release task identity'
require_rollback 'function Invoke-RecoveryForceRelease.*Assert-RecoveryForceReleasePreflight.*Register-ScheduledTask.*Assert-RecoveryForceReleaseTask.*Export-ScheduledTask.*Assert-RecoveryForceReleaseTaskXml.*Start-ScheduledTask.*Assert-RecoveryForceReleaseProcess.*Get-ProcessStartFileTimeString.*Get-ScheduledTaskInfo.*Assert-ForceReleaseReceipt.*finally.*Stop-ScheduledTask.*Wait-RecoveryForceReleaseProcessAbsent.*Unregister-ScheduledTask.*one-shot task was not removed' \
    'one-shot force-release registration, observation, receipt, and cleanup transaction'
require_rollback 'function Assert-RecoveryForceReleaseProcess.*SessionId -ne 1.*Get-ProcessOwnerSid.*Split-WindowsCommandLine.*Assert-ExactArguments.*function Wait-RecoveryForceReleaseProcessAbsent.*exact process zero' \
    'exact Session-1 PID/command/owner and cleanup process-zero proof'
require_rollback '\$forceReleaseTaskContract = Get-RecoveryForceReleaseTaskContract.*Assert-RecoveryForceReleasePreflight -Contract \$forceReleaseTaskContract.*\$validationResult = \[ordered\]@\{.*if \(\$ValidateOnly\).*\[System.IO.File\]::Move\(\$TokenPath, \$consumedTokenPath\)' \
    'full read-only one-shot preflight before ValidateOnly and token consumption'
require_rollback 'function Restore-FileAtomically.*\.rollback\.replace-backup.*\.rollback\.failed-replacement.*\[System\.IO\.File\]::Replace\(.*\$temporary.*\$Destination.*\$replacementBackup.*\$replacementCommitted = \$true.*Restored artifact.*Durable rollback source artifact.*\[System\.IO\.File\]::Replace\(.*\$replacementBackup.*\$Destination.*\$failedReplacement.*Recovered pre-rollback destination' \
    'PS5.1 backup-backed atomic replacement and post-validation compensation'
require_rollback "Backup binary transaction source.*Backup wrapper transaction source.*Open-PrivateFileClaim" \
    'durable rollback sources held by exclusive transaction claims'
require_rollback 'Restore-FileAtomically -Source \$backupBinary.*Restore-FileAtomically -Source \$backupWrapper.*Register-ScheduledTask -TaskPath \$taskPath -TaskName \$taskName.*Stop-ScheduledTask -TaskPath \$taskPath -TaskName \$taskName.*Wait-ReadyInactiveBoundary.*Assert-RestoredScheduledTaskContract' \
    'atomic file restore before Ready/inactive task restoration'
require_rollback 'viewflow-windows-rollback-completed.*exact_process_count = 0.*Write-OwnerOnlyCreateOnceJson' \
    'optional create-once rollback completion receipt'
if rg --quiet 'Start-Process|Stop-Process|taskkill|Invoke-Expression|Invoke-Command|File\]::Replace\([^\n]*\$null' \
    "$rollback"; then
    echo 'standalone rollback contains a forbidden direct start, null-backup replace, force-kill, or code execution path' >&2
    exit 1
fi

require_rollback_test "'Start-Process'.*'Stop-Process'.*'taskkill" \
    'forbidden direct-start and force-kill assertions'
require_rollback_test 'Recovery force-release Session-1 task ordering changed.*Rollback PS5.1 replacement/recovery contract changed' \
    'force-release task and backup-backed replacement static ordering assertions'
require_rollback_test '\[System\.IO\.File\]::Move\(\$TokenPath, \$consumedTokenPath\)' \
    'atomic one-shot rollback-token consumption assertion'
require_rollback_test 'Rollback mutation ordering changed' \
    'token-consume, stable-stop, restore, and registration ordering assertion'
require_rollback_contract_test 'schema_version = 3.*deployment_marker_tool.*viewflow-deployment-marker.*exact_process_count = 0.*legacy schema-2 deactivation proof is rejected.*uppercase marker-tool hash is rejected.*wrong marker-tool path is rejected.*missing marker-tool artifact is rejected.*running marker tool is rejected' \
    'PS5.1 schema-3 marker-tool proof fixtures'
require_rollback_contract_test 'legacy XML LogonTrigger requires compatibility switch.*disabled XML LogonTrigger is rejected.*attributed XML LogonTrigger is rejected.*missing-user XML LogonTrigger is rejected.*wrong-user XML LogonTrigger is rejected.*extra XML LogonTrigger child is rejected.*multiple XML LogonTriggers are rejected.*non-logon XML trigger is rejected.*restored legacy trigger requires compatibility switch.*restored disabled LogonTrigger is rejected.*restored non-Boolean LogonTrigger Enabled is rejected.*restored wrong-user LogonTrigger is rejected.*restored multiple LogonTriggers are rejected' \
    'PS5.1 exact legacy LogonTrigger positive and negative fixtures'
require_rollback_contract_test 'current candidate boundary rejects legacy LogonTrigger.*Assert-CurrentRollbackBoundary -AllowLegacyLogonTrigger.*Restored legacy baseline boundary did not remain Ready and inactive' \
    'PS5.1 resumed baseline legacy-trigger boundary fixture'
require_rollback_contract_test 'wrong explicit RunLevel is rejected.*duplicate RunLevel is rejected.*invalid task XML setting is rejected.*legacy MultipleInstances XML name is rejected.*duplicate required task XML setting is rejected.*missing required task XML setting is rejected.*explicit false optional setting is rejected.*explicit false Enabled is rejected.*duplicate optional setting is rejected.*restart policy is rejected' \
    'PS5.1 reviewed backup XML default/uniqueness negative fixtures'
require_rollback_contract_test '\$defaultedLegacyLogonXml = \$legacyLogonXml\.Replace.*RunLevel>LeastPrivilege.*AllowHardTerminate>true.*Enabled>true.*Assert-TaskXmlContract -Xml \$defaultedLegacyLogonXml -AllowLegacyLogonTrigger' \
    'PS5.1 live-shaped legacy XML defaults fixture'
require_rollback_contract_test 'real Windows PowerShell 5\.1/.NET Framework File\.Replace path.*post-replace validation failure is compensated.*durable source after compensation.*Session-1 recovery force-release task fixture did not complete or clean up exactly once.*force-release task trigger is rejected.*force-release elevated principal is rejected.*force-release Session 0 process is rejected.*pre-existing force-release task is rejected' \
    'PS5.1 atomic compensation and Session-1 one-shot behavioral fixtures'

require_readiness_disconnect_test 'Assert-ThrowsMessage.*ExpectedMessage .Readiness lock is not held by the running daemon..*Write-ReadinessCommitRequest.*Mode .bootstrap-v1\.3..*ForceReceiptSha256 \$lowerSha.*if \(Test-Path -LiteralPath \$requestPath\).*if \(\$requestPublished\).*\$commitTemporaries\.Count -ne 0' \
    'disconnect-before-commit request rejection and temporary-file cleanup assertions'
require_readiness_disconnect_test '\$script:identityChecks -ne 2.*\$script:taskReads -ne 1.*\$script:taskValidations -ne 1.*\$script:taskXmlExports -ne 1.*\$script:taskXmlValidations -ne 1.*Close-AuthenticatedReadinessLease -Readiness \$readiness.*readiness disconnect-before-commit PS5\.1 fixture passed' \
    'full commit-boundary execution and pinned-handle cleanup assertions'
require_readiness_close_test '\$receipt = \[ViewflowTests\.DisposeProbe\]::new\(\$true\).*\$lock = \[ViewflowTests\.DisposeProbe\]::new\(\$false\).*\$receipt\.DisposeCount -ne 1 -or \$lock\.DisposeCount -ne 1.*Assert-LeaseCleared -Lease \$lease.*Repeated readiness close was not idempotent' \
    'single-failure continuation, property clearing, and idempotence assertions'
require_readiness_close_test 'Dual dispose failures were not reported.*\$aggregate\.InnerExceptions\.Count -ne 2.*ReceiptStream.*LockStream.*Assert-LeaseCleared -Lease \$lease.*Repeated dual-failure close disposed a readiness handle twice.*Close-AuthenticatedReadinessLease -Readiness \$null.*readiness lease-close PS5\.1 fixture passed' \
    'dual-failure aggregation and null-safe close assertions'
require_installer 'function Assert-RegularNonReparseFile.*\$item\.PSIsContainer.*ReparsePoint.*function Replace-FileAtomically.*Assert-SafeDirectoryLeaseCurrent.*Get-FileSha256Lower -Path \$destinationFullPath.*-ceq.*\$ExpectedSha256.*return.*\[IO\.File\]::Replace\(\$temporary, \$destinationFullPath, \$backup, \$true\).*\[IO\.File\]::Delete\(\$backup\)' \
    'PS5.1 same-hash idempotence and backup-backed atomic replacement'
require_atomic_replace_test 'same-hash fixture.*LastWriteTimeUtc\.Ticks.*Same-hash replacement rewrote the destination.*different-hash fixture.*Different-hash replacement did not install the expected bytes.*Assert-NoAtomicTemporaryFiles.*installer atomic replacement PS5\.1 fixture passed' \
    'real same-hash and different-hash atomic replacement coverage'
require_installer_union_test 'foreach \(\$mode in @\(.bootstrap-v1\.3., .normal-v2.\)\).*New-RollbackAuthorization.*-RollbackMode \$mode.*Write-RollbackManifest @arguments' \
    'both rollback modes through installer producers'
require_installer_union_test 'Assert-ExactKeys.*rollback_mode.*linux_deactivation_proof_path.*linux_deactivation_transcript_path.*runtime_receipt_path.*daemon_exit_evidence_path.*daemon_exit_observation_path.*Bootstrap rollback manifest retained forbidden daemon observation.*Normal rollback manifest retained forbidden bootstrap evidence' \
    'exact discriminated union and opposite-mode rejection assertions'
require_installer_union_test 'token_sha256 -cne \$token\.Sha256.*rollback_nonce -cne \$token\.Nonce.*user_sid -cne \$expectedTaskUserSid.*task_name -cne \$expectedTaskName.*installer rollback union PS5\.1 fixture passed' \
    'rollback hash, nonce, and identity bindings'
require_installer_union_test 'schema_version=3;state=viewflow-linux-deactivated.*Bootstrap rollback manifest did not require schema-3 proof' \
    'schema-3 bootstrap manifest fixture'

echo "viewflow Windows wrapper, installer, and rollback static checks passed: $script $installer $rollback"
