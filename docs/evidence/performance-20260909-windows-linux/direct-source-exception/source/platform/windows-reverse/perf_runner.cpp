// Bounded GUI launcher; only fixture-owned capture, no input events.
#include <windows.h>
#include <shellapi.h>
#include <dbghelp.h>
#include <string>
#include <cstdio>
#include <cstring>
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int){
 int argc{};auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);if(argc!=2)return 2;std::wstring root=argv[1];LocalFree(argv);
 SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};auto file=[&](const wchar_t* name){return CreateFileW((root+L"\\"+name).c_str(),GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);};
 HANDLE job=CreateJobObjectW(nullptr,nullptr);JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit{};limit.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;if(!job || !SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limit,sizeof(limit)))return 3;
 HANDLE input_read{},input_write{};if(!CreatePipe(&input_read,&input_write,&sa,0))return 4;SetHandleInformation(input_write,HANDLE_FLAG_INHERIT,0);
 HANDLE nul=CreateFileW(L"NUL",GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,nullptr),status=file(L"status.log"),fixture_log=file(L"fixture.log"),source_log=file(L"source.log"),stream=file(L"stream.vfrv");
 auto record=[&](const char* text){DWORD n{};WriteFile(status,text,DWORD(strlen(text)),&n,nullptr);FlushFileBuffers(status);};
 auto launch=[&](const wchar_t* name,std::wstring args,HANDLE in,HANDLE out,HANDLE err,PROCESS_INFORMATION& p){STARTUPINFOW s{sizeof(s)};s.dwFlags=STARTF_USESTDHANDLES|STARTF_USESHOWWINDOW;s.wShowWindow=SW_HIDE;s.hStdInput=in;s.hStdOutput=out;s.hStdError=err;auto exe=root+L"\\build\\Release\\"+name;auto command=L"\""+exe+L"\" "+args;if(!CreateProcessW(exe.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW|CREATE_SUSPENDED|(std::wstring(name)==L"viewflow_windows_reverse.exe"?DEBUG_ONLY_THIS_PROCESS:0),nullptr,root.c_str(),&s,&p))return false;if(!AssignProcessToJobObject(job,p.hProcess)){TerminateProcess(p.hProcess,2);return false;}ResumeThread(p.hThread);CloseHandle(p.hThread);return true;};
 PROCESS_INFORMATION fixture{},source{};if(!launch(L"viewflow_reverse_perf_fixture.exe",L"",nul,nul,fixture_log,fixture)){CloseHandle(job);return 5;}Sleep(1200);
 if(WaitForSingleObject(fixture.hProcess,0)!=WAIT_TIMEOUT){record("fixture_failed\n");CloseHandle(job);return 6;}
 auto selected=std::to_wstring(fixture.dwProcessId);SetEnvironmentVariableW(L"VIEWFLOW_PROFILE_SOURCE_PID",selected.c_str());
 if(!launch(L"viewflow_windows_reverse.exe",L"-6144 -780 0 2676",input_read,stream,source_log,source)){CloseHandle(job);return 7;}CloseHandle(input_read);
 char line[180];std::snprintf(line,sizeof(line),"runner=%lu fixture=%lu source=%lu\n",GetCurrentProcessId(),fixture.dwProcessId,source.dwProcessId);record(line);
 const auto started=GetTickCount64();bool input_closed=false,exited=false;DWORD code=STILL_ACTIVE;
 while(GetTickCount64()-started<40000 && !exited) {
  if(!input_closed && GetTickCount64()-started>=30000){CloseHandle(input_write);input_closed=true;record("input_closed\n");}
  DEBUG_EVENT event{};if(!WaitForDebugEvent(&event,100))continue;DWORD disposition=DBG_CONTINUE;
  if(event.dwDebugEventCode==EXCEPTION_DEBUG_EVENT) {
   auto& e=event.u.Exception;const auto fault=e.ExceptionRecord.ExceptionCode;
   if(fault!=EXCEPTION_BREAKPOINT)disposition=DBG_EXCEPTION_NOT_HANDLED;
   if(fault==0xc0000409 || !e.dwFirstChance) {
    std::snprintf(line,sizeof(line),"exception code=%08lx first=%lu thread=%lu parameters=%lu parameter0=%llu\n",fault,e.dwFirstChance,event.dwThreadId,e.ExceptionRecord.NumberParameters,static_cast<unsigned long long>(e.ExceptionRecord.NumberParameters?e.ExceptionRecord.ExceptionInformation[0]:0));record(line);
    auto thread=OpenThread(THREAD_GET_CONTEXT|THREAD_QUERY_INFORMATION,FALSE,event.dwThreadId);CONTEXT context{};context.ContextFlags=CONTEXT_ALL;
    if(thread && GetThreadContext(thread,&context)) {
     EXCEPTION_POINTERS pointers{&e.ExceptionRecord,&context};MINIDUMP_EXCEPTION_INFORMATION exception{event.dwThreadId,&pointers,FALSE};
     auto dump=CreateFileW((root+L"\\exception.dmp").c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
     const auto ok=dump!=INVALID_HANDLE_VALUE && MiniDumpWriteDump(source.hProcess,source.dwProcessId,dump,static_cast<MINIDUMP_TYPE>(MiniDumpNormal|MiniDumpWithThreadInfo),&exception,nullptr,nullptr);
     std::snprintf(line,sizeof(line),"minidump success=%u error=%lu\n",unsigned(ok),GetLastError());record(line);if(dump!=INVALID_HANDLE_VALUE)CloseHandle(dump);
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
 std::snprintf(line,sizeof(line),"source_exit=%lu watchdog=%u\n",code,unsigned(waited!=WAIT_OBJECT_0));record(line);
 auto fw=WaitForSingleObject(fixture.hProcess,15000);DWORD fc{};GetExitCodeProcess(fixture.hProcess,&fc);std::snprintf(line,sizeof(line),"fixture_exit=%lu watchdog=%u\n",fc,unsigned(fw!=WAIT_OBJECT_0));record(line);
 CloseHandle(job);CloseHandle(source.hProcess);CloseHandle(fixture.hProcess);CloseHandle(fixture_log);CloseHandle(source_log);CloseHandle(stream);CloseHandle(nul);CloseHandle(status);return code==0 && fw==WAIT_OBJECT_0 && fc==0?0:1;
}
