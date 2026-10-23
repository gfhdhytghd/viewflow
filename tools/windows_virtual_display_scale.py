"""Apply a Hyprland monitor's scale in the Windows interactive desktop at startup."""
import base64
import math
import subprocess
import uuid

from desktop_peer_discovery import endpoint_host_port, ssh_args

SUPPORTED_PERCENT = (100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)


def percent_for_monitor(monitor):
    value = float(monitor['scale']) * 100
    if not math.isfinite(value) or value not in SUPPORTED_PERCENT:
        raise ValueError(f'Windows per-monitor scaling cannot represent Hyprland scale {monitor["scale"]}')
    return int(value)


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def encoded(script):
    return base64.b64encode(script.encode('utf-16le')).decode('ascii')


def startup_script(settings, monitor, token):
    percent = percent_for_monitor(monitor)
    device = settings['device']
    utility = settings['utility']
    # SSH runs in Session 0. A short-lived task runs only the display utility in
    # the signed-in user's session; it does not inject input or activate windows.
    worker = f"""
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP {quote(token + '.log')}
$result = Join-Path $env:TEMP {quote(token + '.result')}
try {{
    & {quote(utility)} dpi {quote(device)} {percent} 2>&1 | Out-File -LiteralPath $log -Encoding utf8
    $code = $LASTEXITCODE
    if ($code -ne 0) {{ throw "DPI utility failed: $code" }}
    if (-not (Select-String -LiteralPath $log -SimpleMatch 'dpi_verified={percent}' -Quiet)) {{ throw 'Missing DPI readback' }}
    'ok' | Set-Content -LiteralPath $result
}} catch {{ $_ | Out-File -LiteralPath $log -Append; 'failed' | Set-Content -LiteralPath $result }}
"""
    return f"""
$ErrorActionPreference = 'Stop'
$name = {quote(token)}
$log = Join-Path $env:TEMP ($name + '.log')
$result = Join-Path $env:TEMP ($name + '.result')
$registered = $false
$finished = $false
try {{
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand {encoded(worker)}'
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
    $limits = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 25)
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $limits | Out-Null
    $registered = $true
    Start-ScheduledTask -TaskName $name
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path -LiteralPath $result) -and (Get-Date) -lt $deadline) {{ Start-Sleep -Milliseconds 200 }}
    if (Test-Path -LiteralPath $log) {{ Get-Content -LiteralPath $log }}
    if (-not (Test-Path -LiteralPath $result)) {{ throw 'DPI startup query timed out; Windows user must be logged in' }}
    $finished = $true
    if ((Get-Content -LiteralPath $result).Trim() -ne 'ok') {{ throw 'Windows virtual display scale was not verified' }}
}} finally {{
    if ($registered) {{
        if (-not $finished) {{ Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue }}
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Remove-Item -LiteralPath $log,$result -Force -ErrorAction SilentlyContinue
    }}
}}
"""


def sync_scale(config, endpoint, monitor):
    settings = config['windows_virtual_display']
    script = startup_script(settings, monitor, 'ViewflowDpi-' + uuid.uuid4().hex)
    address, _ = endpoint_host_port(endpoint)
    # Feed the script over stdin: nested UTF-16 EncodedCommand payloads exceed
    # cmd.exe's command-line limit when invoked through Windows OpenSSH.
    script = 'try { & {\n' + script + '\n} } catch { [Console]::Error.WriteLine($_); exit 1 }\n\n'
    subprocess.run(ssh_args(config['peer_discovery'], address) +
                   ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', '-'],
                   input=script, text=True, check=True, timeout=45)
