// Bounded GUI launcher; only fixture-owned capture, no input events.
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <cstdio>
#include <cstring>
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int){
 int argc{};auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);if(argc!=3)return 2;std::wstring root=argv[1],mode=argv[2];LocalFree(argv);if(mode!=L"frame-rate" && mode!=L"latency")return 2;SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_DIAGNOSTICS",L"1");SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_CAPTURE_CHANGES",L"1");SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_DIRECT_SINGLE_SURFACE",L"1");SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_ALPHA_SUMMARY",L"1");
 SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};auto file=[&](const wchar_t* name){return CreateFileW((root+L"\\"+name).c_str(),GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);};
 HANDLE job=CreateJobObjectW(nullptr,nullptr);JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit{};limit.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;if(!job || !SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limit,sizeof(limit)))return 3;
 HANDLE input_read{},input_write{};if(!CreatePipe(&input_read,&input_write,&sa,0))return 4;SetHandleInformation(input_write,HANDLE_FLAG_INHERIT,0);
 HANDLE nul=CreateFileW(L"NUL",GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,nullptr),status=file(L"status.log"),fixture_log=file(L"fixture.log"),source_log=file(L"source.log"),stream=file(L"peer.stdout.log");
 auto record=[&](const char* text){DWORD n{};WriteFile(status,text,DWORD(strlen(text)),&n,nullptr);FlushFileBuffers(status);};
 auto launch=[&](const wchar_t* name,std::wstring args,HANDLE in,HANDLE out,HANDLE err,PROCESS_INFORMATION& p){STARTUPINFOW s{sizeof(s)};s.dwFlags=STARTF_USESTDHANDLES|STARTF_USESHOWWINDOW;s.wShowWindow=SW_HIDE;s.hStdInput=in;s.hStdOutput=out;s.hStdError=err;auto exe=root+L"\\build\\Release\\"+name;auto command=L"\""+exe+L"\" "+args;if(!CreateProcessW(exe.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW|CREATE_SUSPENDED,nullptr,root.c_str(),&s,&p))return false;if(!AssignProcessToJobObject(job,p.hProcess)){TerminateProcess(p.hProcess,2);return false;}ResumeThread(p.hThread);CloseHandle(p.hThread);return true;};
 PROCESS_INFORMATION fixture{},source{};if(!launch(L"viewflow_reverse_perf_fixture.exe",L"",nul,nul,fixture_log,fixture)){CloseHandle(job);return 5;}Sleep(1200);
 if(WaitForSingleObject(fixture.hProcess,0)!=WAIT_TIMEOUT){record("fixture_failed\n");CloseHandle(job);return 6;}
 auto selected=std::to_wstring(fixture.dwProcessId);SetEnvironmentVariableW(L"VIEWFLOW_PROFILE_SOURCE_PID",selected.c_str());
 if(!launch(L"vf-window-perf-peer.exe",L"--config \""+root+L"\\source.json\"",input_read,stream,source_log,source)){CloseHandle(job);return 7;}CloseHandle(input_read);
 char line[180];std::snprintf(line,sizeof(line),"runner=%lu fixture=%lu source=%lu\n",GetCurrentProcessId(),fixture.dwProcessId,source.dwProcessId);record(line);
 auto waited=WaitForSingleObject(source.hProcess,45000);CloseHandle(input_write);
 if(waited==WAIT_TIMEOUT)waited=WaitForSingleObject(source.hProcess,5000);
 if(waited!=WAIT_OBJECT_0){TerminateProcess(source.hProcess,124);WaitForSingleObject(source.hProcess,5000);}DWORD code{};GetExitCodeProcess(source.hProcess,&code);
 std::snprintf(line,sizeof(line),"source_exit=%lu watchdog=%u\n",code,unsigned(waited!=WAIT_OBJECT_0));record(line);
 auto fw=WaitForSingleObject(fixture.hProcess,15000);DWORD fc{};GetExitCodeProcess(fixture.hProcess,&fc);std::snprintf(line,sizeof(line),"fixture_exit=%lu watchdog=%u\n",fc,unsigned(fw!=WAIT_OBJECT_0));record(line);
 CloseHandle(job);CloseHandle(source.hProcess);CloseHandle(fixture.hProcess);CloseHandle(fixture_log);CloseHandle(source_log);CloseHandle(stream);CloseHandle(nul);CloseHandle(status);return code==0 && fw==WAIT_OBJECT_0 && fc==0?0:1;
}
