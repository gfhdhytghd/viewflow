param([Parameter(Mandatory=$true)][string]$Directory)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
New-Item -ItemType Directory "$Directory\requests","$Directory\responses" -Force | Out-Null
Start-Transcript -Path "$Directory\agent.log" -Append | Out-Null
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FusionShell {
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SystemParametersInfo(uint action,uint parameter,IntPtr value,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
 public delegate bool EnumProc(IntPtr h,IntPtr data);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc,IntPtr data);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h,EnumProc proc,IntPtr data);
 [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h,uint cmd);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,System.Text.StringBuilder s,int length);

 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,System.Text.StringBuilder s,int length);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out uint value,int size);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string cls,string title);
 public static string[] Inventory() {
  var rows=new System.Collections.Generic.List<string>();var seen=new System.Collections.Generic.HashSet<IntPtr>();
  EnumProc collect=(h,d)=>{if(!seen.Add(h))return true;uint pid;GetWindowThreadProcessId(h,out pid);try {
   var p=System.Diagnostics.Process.GetProcessById((int)pid);
   if(IsWindowVisible(h) || p.ProcessName=="explorer") {
    var s=new System.Text.StringBuilder(256);GetClassName(h,s,256);uint cloak;int hr=DwmGetWindowAttribute(h,14,out cloak,4);var text=new System.Text.StringBuilder(256);GetWindowText(h,text,256);rows.Add(p.ProcessName+" "+h+" "+s+" owner="+GetWindow(h,4)+" title="+text+" visible="+IsWindowVisible(h)+" cloak="+cloak+" hr="+hr);
   }
  }catch{}return true;};
  EnumWindows(collect,IntPtr.Zero);EnumChildWindows(GetDesktopWindow(),collect,IntPtr.Zero);
  var top=IntPtr.Zero;var topSeen=new System.Collections.Generic.HashSet<IntPtr>();while((top=FindWindowEx(IntPtr.Zero,top,null,null))!=IntPtr.Zero && topSeen.Add(top)) {collect(top,IntPtr.Zero);EnumChildWindows(top,collect,IntPtr.Zero);}
  return rows.ToArray();
 }

 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr GetProp(IntPtr h,string name);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetStyle(IntPtr h,int index);
 public static int[] Status() { int[] result=new int[3]; EnumWindows((h,d)=>{if(GetProp(h,"Viewflow.Fusion.OriginalMinimize.v1")!=IntPtr.Zero){result[0]++;if(IsIconic(h))result[1]++;if((GetStyle(h,-16).ToInt64()&0x20000)!=0)result[2]++;}return true;},IntPtr.Zero);return result; }
 [DllImport("shell32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr ShellExecute(IntPtr h,string verb,string file,string args,string dir,int show);
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct OpenAs { public string file; public string cls; public uint flags; }
 [DllImport("shell32.dll",CharSet=CharSet.Unicode)] public static extern int SHOpenWithDialog(IntPtr owner,ref OpenAs info);
 public static string OfficePath(string app) {
  string exe;
  switch(app) {case "word":exe="WINWORD.EXE";break;case "excel":exe="EXCEL.EXE";break;case "powerpoint":exe="POWERPNT.EXE";break;default:throw new ArgumentException("Unknown Office application");}
  foreach(var hive in new[]{Microsoft.Win32.RegistryHive.CurrentUser,Microsoft.Win32.RegistryHive.LocalMachine})
   foreach(var view in new[]{Microsoft.Win32.RegistryView.Registry64,Microsoft.Win32.RegistryView.Registry32})
    using(var root=Microsoft.Win32.RegistryKey.OpenBaseKey(hive,view))
    using(var key=root.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\"+exe)) {
     var path=key==null?null:key.GetValue(null) as string;
     if(!String.IsNullOrEmpty(path) && System.IO.File.Exists(path.Trim('"')))return path.Trim('"');
    }
  throw new Exception("Office application is not installed: "+app);
 }
 public static void Open(string file,bool choose,string app) {
  if(!String.IsNullOrEmpty(app)) {
   if(choose)throw new ArgumentException("Choose and app are mutually exclusive");
   long result=ShellExecute(IntPtr.Zero,"open",OfficePath(app),"\""+file+"\"",null,1).ToInt64();
   if(result<=32)throw new Exception("Office launch failed: "+result);
   return;
  }
  if(choose) {
   var thread=new System.Threading.Thread(()=>{var info=new OpenAs{file=file,flags=4};int hr=SHOpenWithDialog(IntPtr.Zero,ref info);if(hr<0 && hr!=unchecked((int)0x800704c7))Console.Error.WriteLine("Open With: "+hr);});
   thread.SetApartmentState(System.Threading.ApartmentState.STA);thread.IsBackground=true;thread.Start();
  }
  else { long result=ShellExecute(IntPtr.Zero,"open",file,null,null,1).ToInt64(); if(result<=32)throw new Exception("ShellExecute failed: "+result); }
 }

}
'@
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$script:startButton=$null
function Get-StartButton {
 if($script:startButton) {try {$null=$script:startButton.Current.Name;return $script:startButton} catch {$script:startButton=$null}}
 $tray=[Windows.Automation.AutomationElement]::FromHandle([FusionShell]::FindWindow('Shell_TrayWnd',$null))
 $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,'StartButton')
 $script:startButton=$tray.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
 if(-not $script:startButton){throw 'Windows taskbar StartButton unavailable'}
 return $script:startButton
}
try {$null=Get-StartButton} catch {Write-Warning $_.Exception.Message}
# One interactive agent; SSH itself runs in session 0 and cannot show UI.
$mutex=New-Object Threading.Mutex($false,'Local\ViewflowFusionAgent')
try {if(-not $mutex.WaitOne(5000)){exit 0}} catch [Threading.AbandonedMutexException] {}
$rsa=New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
$rsa.PersistKeyInCsp=$false
[IO.File]::WriteAllText("$Directory\credential-public.xml",$rsa.ToXmlString($false))
try {
 while($true) {
  foreach($file in Get-ChildItem "$Directory\requests\*.json" | Sort-Object Name) {
   $result=@{ok=$false}
   try {
    $request=Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    switch($request.action) {
     'ping' {$result.session=[Diagnostics.Process]::GetCurrentProcess().SessionId;$result.windowPolicy=[FusionShell]::Status()}
     'inventory' {$result.windows=[FusionShell]::Inventory()}
      'shell-controls' {
      Add-Type -AssemblyName UIAutomationClient
      Add-Type -AssemblyName UIAutomationTypes
      $tray=[Windows.Automation.AutomationElement]::FromHandle([FusionShell]::FindWindow('Shell_TrayWnd',$null))
      $items=$tray.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
      $result.controls=@($items|ForEach-Object {@{name=$_.Current.Name;id=$_.Current.AutomationId;type=$_.Current.ControlType.ProgrammaticName;offscreen=$_.Current.IsOffscreen;patterns=@($_.GetSupportedPatterns()|ForEach-Object {$_.ProgrammaticName})}})
     }
     'screenshot' {
      Add-Type -AssemblyName System.Drawing
      $image=New-Object Drawing.Bitmap(6144,3456)
      $graphics=[Drawing.Graphics]::FromImage($image)
      try {$graphics.CopyFromScreen(0,0,0,0,$image.Size);$image.Save((Join-Path $Directory 'desktop.png'),[Drawing.Imaging.ImageFormat]::Png)} finally {$graphics.Dispose();$image.Dispose()}
     }
      'dismiss-start' {
      $toggle=(Get-StartButton).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
      if($toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::On){$toggle.Toggle()}
     }
      'start' {
      @{time=[DateTime]::UtcNow.ToString('o');event='start-request'} | ConvertTo-Json -Compress | Add-Content "$Directory\start-events.jsonl" -Encoding UTF8
      $button=Get-StartButton
      $toggle=$button.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
      $result.before=[string]$toggle.Current.ToggleState
      # Disable shell menu/client-area animations for this interactive session.
      [FusionShell]::SystemParametersInfo(0x1043,0,[IntPtr]::Zero,2) | Out-Null
      [FusionShell]::SystemParametersInfo(0x1003,0,[IntPtr]::Zero,2) | Out-Null
      if($toggle.Current.ToggleState -ne [Windows.Automation.ToggleState]::On){$toggle.Toggle()}
      $result.after=[string]$toggle.Current.ToggleState
      @{time=[DateTime]::UtcNow.ToString('o');event='start-observed';before=$result.before;after=$result.after} | ConvertTo-Json -Compress | Add-Content "$Directory\start-events.jsonl" -Encoding UTF8
     }
     'applications' {$result.applications=@{};foreach($app in 'word','excel','powerpoint'){$result.applications[$app]=[FusionShell]::OfficePath($app)}}
     'open' {
      foreach($path in $request.paths) {
       if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Shared file unavailable: $path"}
       [FusionShell]::Open([string]$path,[bool]$request.choose,[string]$request.app)
      }
     }
     'fusion' {
      $value=if($request.enabled){'on'}else{'off'}
      [IO.File]::WriteAllText("$Directory\mode.next",$value)
      Move-Item "$Directory\mode.next" "$Directory\mode" -Force
     }
     'share-status' {
      $result.connections=(& net.exe use | Out-String)
      $result.files=@(foreach($path in $request.paths){try {$item=Get-Item -LiteralPath $path;@{path=$path;exists=$true;length=$item.Length}}catch{@{path=$path;exists=$false;error=$_.Exception.Message}}})
     }
     'share-check' {
      $path=[string]$request.path
      if(-not [IO.File]::Exists($path)) {
       $parent=[IO.Path]::GetDirectoryName($path)
       throw "Shared file missing; directory=$([IO.Directory]::Exists($parent)); matching_test_files=$([string]::Join(',', [IO.Directory]::GetFiles($parent,'fusion-*')))"
      }
      $value=[IO.File]::ReadAllText($path)
      [IO.File]::WriteAllText($path,$value+"`nwindows-write-ok")
      $result.content=$value
     }
     'credential' {
      # Only RSA ciphertext crosses the file inbox. Plaintext stays in memory
      # and the helper's stdin, then Windows Credential Manager stores it.
      $bytes=$rsa.Decrypt([Convert]::FromBase64String($request.encrypted),$true)
      $password=[Text.Encoding]::UTF8.GetString($bytes)
      $si=New-Object Diagnostics.ProcessStartInfo
      $si.FileName=Join-Path (Split-Path $Directory) 'build\Release\viewflow_autologon.exe'
      $si.Arguments='credential '+[string]$request.user+' '+[string]$request.server
      $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardError=$true;$si.RedirectStandardOutput=$true
      $p=[Diagnostics.Process]::Start($si)
      $p.StandardInput.WriteLine($password);$p.StandardInput.Close();$p.WaitForExit()
      [Array]::Clear($bytes,0,$bytes.Length);$password=$null
      if($p.ExitCode){throw "Credential Manager setup failed: $($p.StandardError.ReadToEnd())"}
     }
     default {throw "Unknown fusion action"}
    }
    $result.ok=$true
   } catch {$result.error=$_.Exception.Message}
   $response=Join-Path "$Directory\responses" $file.Name
   $result | ConvertTo-Json -Depth 5 -Compress | Set-Content "$response.next" -Encoding UTF8
   Move-Item "$response.next" $response -Force
   Remove-Item $file.FullName -Force
  }
  Start-Sleep -Milliseconds 20
 }
} finally {$rsa.Dispose();$mutex.ReleaseMutex();$mutex.Dispose()}
