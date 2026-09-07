[CmdletBinding()]
param([string]$Root = "$env:LOCALAPPDATA\Viewflow\wallpaper", [switch]$Once, [switch]$Restore)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Root | Out-Null
Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace ViewflowWallpaper {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
 [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface Desktop {
  void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.LPWStr)] string path);
  void GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.LPWStr)] out string path);
  void GetMonitorDevicePathAt(uint index, [MarshalAs(UnmanagedType.LPWStr)] out string id);
  void GetMonitorDevicePathCount(out uint count);
  void GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string id, out Rect rect);
  void SetBackgroundColor(uint color);
  void GetBackgroundColor(out uint color);
  void SetPosition(int position);
  void GetPosition(out int position);
 }
 public static class Api {
  static Desktop desktop;
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  public static void Open() {
   SetThreadDpiAwarenessContext(new IntPtr(-4));
   desktop = (Desktop)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD")));
  }
  public static uint Count() { uint n; desktop.GetMonitorDevicePathCount(out n); return n; }
  public static string Id(uint i) { string id; desktop.GetMonitorDevicePathAt(i, out id); return id; }
  public static Rect Bounds(string id) { Rect r; desktop.GetMonitorRECT(id, out r); return r; }
  public static string Wallpaper(string id) { string p; desktop.GetWallpaper(id, out p); return p; }
  public static int Position() { int p; desktop.GetPosition(out p); return p; }
  public static void Set(string id, string path) { desktop.SetWallpaper(id, path); }
  public static void Save(string path, string json) {
   string next = path + ".next";
   System.IO.File.WriteAllText(next, json, new System.Text.UTF8Encoding(false));
   if (System.IO.File.Exists(path)) System.IO.File.Replace(next, path, null);
   else System.IO.File.Move(next, path);
  }
 }
}
'@
[ViewflowWallpaper.Api]::Open()
function Inventory {
    $count = [ViewflowWallpaper.Api]::Count()
    for ([uint32]$i = 0; $i -lt $count; $i++) {
        $id = [ViewflowWallpaper.Api]::Id($i)
        $r = [ViewflowWallpaper.Api]::Bounds($id)
        $path = [ViewflowWallpaper.Api]::Wallpaper($id)
        [pscustomobject]@{id=$id; path=$path; rect=@($r.Left,$r.Top,$r.Right,$r.Bottom)}
    }
}
function Save-Json($Path, $Value) {
    [ViewflowWallpaper.Api]::Save($Path, ($Value | ConvertTo-Json -Depth 6))
}
if ($Restore) {
    $backup = Get-Content -Raw -LiteralPath "$Root\backup.json" | ConvertFrom-Json
    [ViewflowWallpaper.Api]::Set($backup.id, $backup.path)
    exit 0
}
$last = ''
do {
    try {
        $request = Get-Content -Raw -LiteralPath "$Root\request.json" | ConvertFrom-Json
        if ($request.version -ne 1 -or $request.sha256 -notmatch '^[a-f0-9]{64}$' -or $request.rect.Count -ne 4) { throw 'Invalid wallpaper manifest' }
        $image = Join-Path $Root ($request.sha256 + '.png')
        $all = @(Inventory)
        $matches = @($all | Where-Object { ($_.rect -join ',') -eq ($request.rect -join ',') })
        if ($matches.Count -ne 1) { throw 'Waiting for configured virtual monitor rectangle' }
        $target = $matches[0]
        $position = [ViewflowWallpaper.Api]::Position()
        if ($position -eq 5) { throw 'Windows span wallpaper mode needs a desktop-wide image; per-monitor sync cannot preserve that layout' }
        $key = $request.sha256 + $target.id + ($target.rect -join ',')
        if ($key -ne $last -or $target.path -ne $image) {
            if ((Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash.ToLowerInvariant() -ne $request.sha256) { throw 'Wallpaper transfer is incomplete' }
            Add-Type -AssemblyName System.Drawing
            $bitmap = [Drawing.Image]::FromFile($image)
            try {
                if ($bitmap.Width -ne ($target.rect[2]-$target.rect[0]) -or $bitmap.Height -ne ($target.rect[3]-$target.rect[1])) { throw 'Wallpaper dimensions differ from virtual monitor' }
            } finally { $bitmap.Dispose() }
            if (-not (Test-Path -LiteralPath "$Root\backup.json")) { Save-Json "$Root\backup.json" $target }
            [ViewflowWallpaper.Api]::Set($target.id, $image)
            $after = @(Inventory)
            $actual = @($after | Where-Object id -eq $target.id)[0]
            if ($actual.path -ne $image) { throw 'Windows did not retain the requested wallpaper' }
            $othersUnchanged = $true
            foreach ($other in $all) {
                if ($other.id -eq $target.id) { continue }
                $now = @($after | Where-Object id -eq $other.id)
                if ($now.Count -ne 1 -or $now[0].path -ne $other.path) { $othersUnchanged = $false }
            }
            Save-Json "$Root\receipt.json" @{version=1; sha256=$request.sha256; monitor=$target.id; rect=$actual.rect; path=$actual.path; others_unchanged=$othersUnchanged; session=[Diagnostics.Process]::GetCurrentProcess().SessionId; applied_utc=[DateTime]::UtcNow.ToString('o')}
            $last = $key
            Remove-Item -LiteralPath "$Root\error.json" -ErrorAction SilentlyContinue
            Write-Output "Wallpaper applied: $($request.sha256), other monitors unchanged=$othersUnchanged"
        }
    } catch {
        Save-Json "$Root\error.json" @{error=$_.Exception.Message; utc=[DateTime]::UtcNow.ToString('o')}
        if ($Once) { throw }
    }
    if (-not $Once) { Start-Sleep -Seconds 3 }
} while (-not $Once)
