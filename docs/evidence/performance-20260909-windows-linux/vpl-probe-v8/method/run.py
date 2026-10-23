from pathlib import Path
import subprocess,base64,json,sys
b=Path(__file__).resolve().parent.parent
remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-vpl-probe-v8-20260909'
label=sys.argv[1];low=int(sys.argv[2]);tiles=int(sys.argv[3]);assert tiles in (1,2,4);assert label.replace('-','').isalnum() and low in (0,1)
out=b/'runs'/label;out.mkdir(parents=True)
def ps(s,timeout=35):
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 return r
s="$main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString();if($main -eq 'Running'){throw 'main running'};if(@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -like '*reverse-vpl-probe-v8-20260909*'}).Count){throw 'probe running'};Set-Location '"+remote+"';if(Test-Path '"+label+".log'){throw 'exists'};cmd.exe /d /c 'probe.exe "+str(low)+" 6144 3456 "+label+".hevc "+str(tiles)+" > "+label+".log 2>&1';$code=$LASTEXITCODE;Get-Content '"+label+".log';exit $code"
r=ps(s,90);(out/'probe.log').write_bytes(r.stdout);(out/'ssh.log').write_bytes(r.stderr);(out/'status.json').write_text(json.dumps({'exit':r.returncode,'low_power':low,'tile_columns':tiles,'native':remote+r'\probe.exe'},indent=2)+'\n');print(r.stdout.decode(errors='replace')[-1800:]);print('EXIT',r.returncode)
subprocess.run(['scp','-q','wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+label+'.hevc',str(out/'probe.hevc')],check=True,timeout=60)
state=ps("[pscustomobject]@{main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString();processes=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -like '*reverse-vpl-probe-v8-20260909*'}|Select-Object ProcessId,ExecutablePath);native=(Get-FileHash '"+remote+"\\probe.exe').Hash;installed=(Get-FileHash 'C:\\Users\\wilf\\Viewflow\\desktop-test\\viewflow_windows_reverse.exe').Hash;runtime=(Get-FileHash 'C:\\Windows\\System32\\libvpl.dll').Hash}|ConvertTo-Json -Depth 4");assert state.returncode==0;(out/'state.json').write_bytes(state.stdout)
