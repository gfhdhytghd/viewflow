param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ExecutableSha256,
    [Parameter(Mandatory = $true)][int]$ExpectedSessionId
)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $Root 'platform\windows-proxy-probe\target\release\proxy_smoke.exe'
$report = Join-Path $Root 'native-report.jsonl'
$outcome = Join-Path $Root 'outcome.json'
$stdout = Join-Path $Root 'stdout.log'
$stderr = Join-Path $Root 'stderr.log'
foreach ($path in @($report, $outcome, $stdout, $stderr)) {
    if (Test-Path -LiteralPath $path) { throw "Probe output already exists: $path" }
}
if ($ExpectedSessionId -le 0 -or [Diagnostics.Process]::GetCurrentProcess().SessionId -ne $ExpectedSessionId) {
    throw 'Probe must run in the requested interactive user session'
}
if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -cne $ExecutableSha256.ToUpperInvariant()) {
    throw 'Probe executable SHA differs'
}
$child = Start-Process -FilePath $exe -ArgumentList ('"' + $report + '"') -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
try {
    # Open the process handle before it exits; Windows PowerShell otherwise
    # may report a null ExitCode for a short-lived Start-Process child.
    $null = $child.Handle
    $session = $child.SessionId
    if (-not $child.WaitForExit(10000)) {
        $child.Kill()
        $child.WaitForExit()
        throw 'Native proxy probe exceeded 10 seconds'
    }
    if ($null -eq $child.ExitCode) { throw 'Native child exit code was not observed' }
    $result = [ordered]@{
        schema_version = 1
        process_id = $child.Id
        session_id = $session
        exit_code = $child.ExitCode
        executable_sha256 = $ExecutableSha256.ToLowerInvariant()
        completed_at_utc = [DateTime]::UtcNow.ToString('o')
        visual_verified = $false
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Compress))
    $file = [IO.File]::Open($outcome, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
    if ($session -ne $ExpectedSessionId -or $child.ExitCode -ne 0) { exit 1 }
} finally { $child.Dispose() }
