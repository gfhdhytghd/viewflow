param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [Parameter(Mandatory=$true)][string]$OutputPrefix,
    [ValidateSet('sta','mta','worker-mta','direct-d3d','direct-d3d-1080','mta-two-workers')][string]$Mode = 'mta'
)
$ErrorActionPreference = 'Stop'
# Diagnostic only. The executable has its own 10-second self watchdog.
# Persist both pipes before waiting so a stuck driver cannot erase the trace.
$paths = @("${OutputPrefix}.stdout", "${OutputPrefix}.stderr", "${OutputPrefix}.json")
foreach ($path in $paths) { if (Test-Path -LiteralPath $path) { throw 'output exists' } }
$stdout = [IO.FileStream]::new($paths[0], [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read, 1, [IO.FileOptions]::WriteThrough)
$stderr = $null
$process = $null
$outPump = $null
$errPump = $null
$receipt = [ordered]@{mode=$Mode;pid=$null;session=$null;exited=$false;exit=$null;stdoutComplete=$false;stderrComplete=$false;error=$null}
try {
    $stderr = [IO.FileStream]::new($paths[1], [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read, 1, [IO.FileOptions]::WriteThrough)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Resolve-Path -LiteralPath $Executable).Path
    $info.Arguments = $Mode
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'start failed' }
    $receipt.pid = $process.Id
    $receipt.session = $process.SessionId
    $outPump = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $errPump = $process.StandardError.BaseStream.CopyToAsync($stderr)
    $receipt.exited = $process.WaitForExit(15000)
    if ($receipt.exited) { $receipt.exit = $process.ExitCode }
    else { $receipt.error = 'self watchdog did not complete process termination; do not start another probe' }
} catch { $receipt.error = $_.Exception.Message }
finally {
    foreach ($entry in @(@($outPump,'stdoutComplete'), @($errPump,'stderrComplete'))) {
        if ($null -ne $entry[0]) {
            try { $receipt[$entry[1]] = $entry[0].Wait(500) }
            catch { $receipt.error = $_.Exception.Message }
        }
    }
    # Pending pumps own their streams until this harness exits. Never block on EOF.
    if ($null -eq $outPump -or $receipt.stdoutComplete) { $stdout.Dispose() }
    if ($null -ne $stderr -and ($null -eq $errPump -or $receipt.stderrComplete)) { $stderr.Dispose() }
    $json = [Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Compress))
    $file = [IO.FileStream]::new($paths[2], [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $file.Write($json,0,$json.Length); $file.Flush($true) } finally { $file.Dispose() }
    if ($null -ne $process) { $process.Dispose() }
}
if (-not $receipt.exited -or $null -ne $receipt.error) { exit 1 }
exit $receipt.exit
