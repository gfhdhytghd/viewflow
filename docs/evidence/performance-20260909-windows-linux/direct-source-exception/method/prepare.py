from pathlib import Path
import shutil,subprocess,base64,hashlib,json
base=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');a=base/'direct-source-rt';b=base/'direct-source-exception';assert not b.exists();shutil.copytree(a/'source',b/'source');(b/'method').mkdir();(b/'runs').mkdir();remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-direct-source-exception-20260909';origin=remote.replace('source-exception','source-rt')
p=b/'source/platform/windows-reverse/perf_runner.cpp';s=p.read_text().replace('#include <shellapi.h>','#include <shellapi.h>\n#include <dbghelp.h>')
needle='CREATE_NO_WINDOW|CREATE_SUSPENDED,nullptr';assert s.count(needle)==1;s=s.replace(needle,'CREATE_NO_WINDOW|CREATE_SUSPENDED|(std::wstring(name)==L"viewflow_windows_reverse.exe"?DEBUG_ONLY_THIS_PROCESS:0),nullptr')
start=s.index(' auto waited=WaitForSingleObject(source.hProcess,30000);');end=s.index(' std::snprintf(line,sizeof(line),"source_exit=',start)
s=s[:start]+''' const auto started=GetTickCount64();bool input_closed=false,exited=false;DWORD code=STILL_ACTIVE;
 while(GetTickCount64()-started<40000 && !exited) {
  if(!input_closed && GetTickCount64()-started>=30000){CloseHandle(input_write);input_closed=true;record("input_closed\\n");}
  DEBUG_EVENT event{};if(!WaitForDebugEvent(&event,100))continue;DWORD disposition=DBG_CONTINUE;
  if(event.dwDebugEventCode==EXCEPTION_DEBUG_EVENT) {
   auto& e=event.u.Exception;const auto fault=e.ExceptionRecord.ExceptionCode;
   if(fault!=EXCEPTION_BREAKPOINT)disposition=DBG_EXCEPTION_NOT_HANDLED;
   if(fault==0xc0000409 || !e.dwFirstChance) {
    std::snprintf(line,sizeof(line),"exception code=%08lx first=%lu thread=%lu parameters=%lu parameter0=%llu\\n",fault,e.dwFirstChance,event.dwThreadId,e.ExceptionRecord.NumberParameters,static_cast<unsigned long long>(e.ExceptionRecord.NumberParameters?e.ExceptionRecord.ExceptionInformation[0]:0));record(line);
    auto thread=OpenThread(THREAD_GET_CONTEXT|THREAD_QUERY_INFORMATION,FALSE,event.dwThreadId);CONTEXT context{};context.ContextFlags=CONTEXT_ALL;
    if(thread && GetThreadContext(thread,&context)) {
     EXCEPTION_POINTERS pointers{&e.ExceptionRecord,&context};MINIDUMP_EXCEPTION_INFORMATION exception{event.dwThreadId,&pointers,FALSE};
     auto dump=CreateFileW((root+L"\\\\exception.dmp").c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
     const auto ok=dump!=INVALID_HANDLE_VALUE && MiniDumpWriteDump(source.hProcess,source.dwProcessId,dump,static_cast<MINIDUMP_TYPE>(MiniDumpNormal|MiniDumpWithThreadInfo),&exception,nullptr,nullptr);
     std::snprintf(line,sizeof(line),"minidump success=%u error=%lu\\n",unsigned(ok),GetLastError());record(line);if(dump!=INVALID_HANDLE_VALUE)CloseHandle(dump);
    }
    if(thread)CloseHandle(thread);
   }
  } else if(event.dwDebugEventCode==EXIT_PROCESS_DEBUG_EVENT){exited=true;code=event.u.ExitProcess.dwExitCode;}
  else if(event.dwDebugEventCode==CREATE_PROCESS_DEBUG_EVENT && event.u.CreateProcessInfo.hFile)CloseHandle(event.u.CreateProcessInfo.hFile);
  else if(event.dwDebugEventCode==LOAD_DLL_DEBUG_EVENT && event.u.LoadDll.hFile)CloseHandle(event.u.LoadDll.hFile);
  ContinueDebugEvent(event.dwProcessId,event.dwThreadId,disposition);
 }
 if(!input_closed)CloseHandle(input_write);
 auto waited=exited?WAIT_OBJECT_0:WAIT_TIMEOUT;
 if(!exited){TerminateProcess(source.hProcess,124);WaitForSingleObject(source.hProcess,5000);GetExitCodeProcess(source.hProcess,&code);}
'''+s[end:];p.write_text(s)
c=b/'method/build.cmd';c.write_text('@echo off\ncall "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"\nif errorlevel 1 exit /b %errorlevel%\ncl /nologo /O2 /std:c++20 /EHsc /DUNICODE /D_UNICODE source\\platform\\windows-reverse\\perf_runner.cpp /Fe:build\\Release\\viewflow_reverse_perf_runner.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib dbghelp.lib\nexit /b %errorlevel%\n')
s=(a/'method/run-source.py').read_text().replace('reverse-direct-source-rt-20260909','reverse-direct-source-exception-20260909').replace('Reverse6KDirectSourceRT-20260909','Reverse6KDirectSourceException-20260909');(b/'method/run-source.py').write_text(s)
def ps(s):
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=120);assert r.returncode==0,(r.stdout+r.stderr).decode(errors='replace');return r.stdout.decode(errors='replace')
ps("if(Test-Path '"+remote+"'){throw 'exists'};New-Item -ItemType Directory '"+remote+"'|Out-Null;Copy-Item '"+origin+"\\source' '"+remote+"\\source' -Recurse;New-Item -ItemType Directory '"+remote+"\\build'|Out-Null;Copy-Item '"+origin+"\\build\\Release' '"+remote+"\\build\\Release' -Recurse")
for f,d in [(p,'source/platform/windows-reverse/perf_runner.cpp'),(c,'build.cmd')]:subprocess.run(['scp','-q',str(f),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+d],check=True,timeout=30)
m={str(f.relative_to(b/'source')):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted((b/'source').rglob('*')) if f.is_file()};(b/'method/source-sha256.json').write_text(json.dumps(m,indent=2)+'\n')
log=ps("Set-Location '"+remote+"';cmd.exe /d /c 'build.cmd > build.log 2>&1';$code=$LASTEXITCODE;Get-Content build.log;exit $code");(b/'method/build.log').write_text(log);print(log[-1200:]);(b/'method/prepare.py').write_text(Path(__file__).read_text())
