param(
    [Parameter(Mandatory=$true)][string]$Peer,
    [Parameter(Mandatory=$true)][string]$Config,
    [Parameter(Mandatory=$true)][string]$LogDirectory
)
# Run from a user Interactive scheduled task with an AtLogOn trigger.
# Capture requires a logged-in desktop; no password or automatic login is set.
$ErrorActionPreference='Stop'
$env:VIEWFLOW_WINDOWS_INPUT_SERVICE='1'
# Capture directly into leased readback buffers; set 0 to use owned GPU textures.
if (-not $env:VIEWFLOW_SHM_CAPTURE_STAGING) { $env:VIEWFLOW_SHM_CAPTURE_STAGING='1' }
# Four participants reduce large BGRA publication time; explicit 2 retains the fallback.
if (-not $env:VIEWFLOW_SHM_COPY_THREADS) { $env:VIEWFLOW_SHM_COPY_THREADS='4' }
# Runtime CPU/OS feature checks retain SSE2 when AVX2 is unavailable; 0 opts out.
if (-not $env:VIEWFLOW_SHM_COPY_AVX2) { $env:VIEWFLOW_SHM_COPY_AVX2='1' }
# Windows 26100 defaults WGC to a 16 ms minimum, which can miss a 60 Hz
# update after scheduling jitter. 4000 requests 4 ms; 0 retains the OS default.
if (-not $env:VIEWFLOW_WGC_INTERVAL_US) { $env:VIEWFLOW_WGC_INTERVAL_US='4000' }
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
while ($true) {
    foreach ($name in @('session.stdout.log','session.stderr.log')) {
        $path=Join-Path $LogDirectory $name
        if (Test-Path $path) { Move-Item $path "$path.previous" -Force }
    }
    try {
        $p=Start-Process -NoNewWindow -FilePath $Peer -ArgumentList @('--config',('"'+$Config+'"')) -PassThru -RedirectStandardOutput (Join-Path $LogDirectory 'session.stdout.log') -RedirectStandardError (Join-Path $LogDirectory 'session.stderr.log')
        $p.WaitForExit()
    } catch {
        Add-Content (Join-Path $LogDirectory 'session.stderr.log') "Peer launch failed: $_"
    }
    Start-Sleep -Seconds 2
}
