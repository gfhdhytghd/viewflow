#include <windows.h>
#include <shellapi.h>
#include <string>
#include <cstdio>
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
 int argc=0;auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);if(!argv||argc!=7)return 2;
 std::wstring exe=argv[1],nonce=argv[2],port=argv[3],batches=argv[4],dir=argv[5],mode=argv[6];LocalFree(argv);
 if(port!=L"49101"||(mode!=L"blocking"&&mode!=L"nonblocking"))return 2;
 SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};auto file=[&](const wchar_t* n){return CreateFileW((dir+L"\\"+n).c_str(),GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);};
 HANDLE output=file(L"probe-output.log"),status=file(L"probe-status.log"),input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,nullptr),job=CreateJobObjectW(nullptr,nullptr);
 if(output==INVALID_HANDLE_VALUE||status==INVALID_HANDLE_VALUE||input==INVALID_HANDLE_VALUE||!job)return 3;
 JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;if(!SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limits,sizeof(limits)))return 4;
 SetEnvironmentVariableW(L"VIEWFLOW_PROBE_IO",mode.c_str());
 STARTUPINFOW startup{sizeof(startup)};startup.dwFlags=STARTF_USESTDHANDLES|STARTF_USESHOWWINDOW;startup.wShowWindow=SW_HIDE;startup.hStdInput=input;startup.hStdOutput=output;startup.hStdError=output;
 std::wstring command=L"\""+exe+L"\" "+nonce+L" "+port+L" "+batches;PROCESS_INFORMATION process{};
 if(!CreateProcessW(exe.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW|CREATE_SUSPENDED,nullptr,dir.c_str(),&startup,&process))return 5;
 if(!AssignProcessToJobObject(job,process.hProcess)){TerminateProcess(process.hProcess,5);return 5;}
 DWORD session=0;ProcessIdToSessionId(process.dwProcessId,&session);char line[200];auto record=[&](const char* s){DWORD n=0;WriteFile(status,s,DWORD(strlen(s)),&n,nullptr);FlushFileBuffers(status);};
 std::snprintf(line,sizeof(line),"runner_pid=%lu probe_pid=%lu session=%lu\n",GetCurrentProcessId(),process.dwProcessId,session);record(line);
 ResumeThread(process.hThread);CloseHandle(process.hThread);DWORD waited=WaitForSingleObject(process.hProcess,35000);if(waited!=WAIT_OBJECT_0){TerminateJobObject(job,ERROR_TIMEOUT);WaitForSingleObject(process.hProcess,5000);}
 DWORD code=1;GetExitCodeProcess(process.hProcess,&code);std::snprintf(line,sizeof(line),"probe_exit=%lu watchdog=%u\n",code,unsigned(waited!=WAIT_OBJECT_0));record(line);
 CloseHandle(process.hProcess);CloseHandle(job);CloseHandle(input);CloseHandle(output);CloseHandle(status);return waited==WAIT_OBJECT_0?int(code):124;
}
