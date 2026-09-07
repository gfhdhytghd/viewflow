param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$Receiver,
    [Parameter(Mandatory=$true)][string]$Presenter,
    [Parameter(Mandatory=$true)][string]$Log
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Log) { throw 'Diagnostic log already exists' }
$receiverArguments = @(
    'receive', '--listen', '172.16.105.70:44339', '--server-name', 'viewflow-test.local',
    '--cert', (Join-Path $Root 'peer.pem'), '--key', (Join-Path $Root 'peer.key'),
    '--ca', (Join-Path $Root 'ca.pem'), '--max-frame-bytes', '33554432',
    '--timeout-ms', '30000', '--stdin-compressed', $Presenter
)
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $Receiver
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.Arguments = (($receiverArguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' ')
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
try {
    if (-not $process.Start()) { throw 'Receiver did not start' }
    $receiverProcessId = $process.Id
    $receiverStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
    # Drain both streams while the process runs, not after WaitForExit.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $completed = $process.WaitForExit(35000)
    if (-not $completed) {
        # Only the process tree started by this diagnostic is in scope.
        & taskkill.exe /PID $receiverProcessId /T /F | Out-Null
        if (-not $process.WaitForExit(5000)) { throw 'Receiver tree did not exit' }
    }
    $result = [ordered]@{
        childPID = $receiverProcessId
        childStartUtc = $receiverStartUtc
        timedOut = -not $completed
        exit = $process.ExitCode
        stdout = $stdoutTask.GetAwaiter().GetResult()
        stderr = $stderrTask.GetAwaiter().GetResult()
        completedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $json = $result | ConvertTo-Json -Depth 4
    $file = [IO.File]::Open($Log, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $file.Write($bytes, 0, $bytes.Length)
        $file.Flush()
    } finally { $file.Dispose() }
} finally { $process.Dispose() }
