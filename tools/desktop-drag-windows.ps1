[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Config,
    [string] $StagingRoot = 'C:\Users\wilf\Viewflow\desktop-test',
    [string] $Binary = 'C:\Users\wilf\Viewflow\desktop-test\vf-media-peer.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('ViewflowDisplayInventory' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ViewflowDisplayInventory {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; }
  public delegate bool MonitorEnum(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnum callback, IntPtr data);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);
  public static string[] Rectangles() {
    var all = new List<string>();
    var previous = SetThreadDpiAwarenessContext(new IntPtr(-4)); // PER_MONITOR_AWARE_V2
    try {
      EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (monitor, hdc, rect, data) => {
        var info = new MONITORINFO(); info.cbSize = Marshal.SizeOf(info);
        if (!GetMonitorInfo(monitor, ref info)) return false;
        var r = info.rcMonitor;
        all.Add(r.Left + "," + r.Top + "," + (r.Right-r.Left) + "," + (r.Bottom-r.Top));
        return true;
      }, IntPtr.Zero);
    } finally {
      if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous);
    }
    return all.ToArray();
  }
}
'@
}

function Require-ExistingFile([string] $Path, [string] $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label does not exist: $Path"
    }
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
}

function Require-UnderRoot([string] $Path, [string] $Root, [string] $Label) {
    $rootPrefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $Path.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be under the verified staging root: $Root"
    }
}

if (-not (Test-Path -LiteralPath $StagingRoot -PathType Container)) {
    throw "The required staging directory does not exist: $StagingRoot"
}
$resolvedRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $StagingRoot).Path)
$resolvedConfig = Require-ExistingFile $Config 'Config'
$resolvedBinary = Require-ExistingFile $Binary 'vf-media-peer.exe'
Require-UnderRoot $resolvedConfig $resolvedRoot 'Config'
Require-UnderRoot $resolvedBinary $resolvedRoot 'vf-media-peer.exe'

$policy = Get-Content -LiteralPath $resolvedConfig -Raw | ConvertFrom-Json
if ($null -eq $policy.desktop) { throw 'Receiver config must include desktop placement policy.' }
$display = $policy.desktop.display
if ($null -eq $display) { throw 'Receiver desktop policy must include display resolution, scale and global coordinates.' }
foreach ($field in 'x', 'y', 'width', 'height', 'scale') {
    if ($null -eq $display.$field) { throw "Receiver display is missing $field." }
}
if ([int64]$display.width -lt 1 -or [int64]$display.height -lt 1) {
    throw 'Receiver display width and height must be positive physical pixels.'
}
if ([double]$display.scale -lt 0.125 -or [double]$display.scale -gt 8) {
    throw 'Receiver display scale must be a factor between 0.125 and 8, such as 1.5.'
}
$nativeX = 0
$nativeY = 0
if ($null -ne $policy.desktop.PSObject.Properties['native_x']) { $nativeX = [int64]$policy.desktop.native_x }
if ($null -ne $policy.desktop.PSObject.Properties['native_y']) { $nativeY = [int64]$policy.desktop.native_y }
$targetRight = $nativeX + [int64]$display.width
$targetBottom = $nativeY + [int64]$display.height
$containingMonitor = $false
foreach ($rectangle in [ViewflowDisplayInventory]::Rectangles()) {
    $parts = $rectangle.Split(',')
    $left = [int64]$parts[0]
    $top = [int64]$parts[1]
    $width = [int64]$parts[2]
    $height = [int64]$parts[3]
    if ($nativeX -ge $left -and $nativeY -ge $top -and
        $targetRight -le ($left + $width) -and $targetBottom -le ($top + $height)) {
        $containingMonitor = $true
        break
    }
}
if (-not $containingMonitor) {
    throw 'Configured receiver physical viewport is not contained by a monitor in this Windows desktop session.'
}

& $resolvedBinary validate-receive --config $resolvedConfig
if ($LASTEXITCODE -ne 0) {
    throw "Receiver configuration failed offline validation (exit $LASTEXITCODE)."
}

Write-Host 'Viewflow receiver starts now. On the Windows proxy, use Win + left-drag to request a native move.'
Write-Host 'The configured physical viewport was found in this desktop session. This launcher does not synthesize input, copy files, or modify display settings.'
& $resolvedBinary receive --config $resolvedConfig
exit $LASTEXITCODE
