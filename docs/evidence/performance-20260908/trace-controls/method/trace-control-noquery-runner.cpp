// GUI test launcher: bounded lifetime, private job, no console or input APIs.
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <cstdio>
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
  int argc=0;auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);
  if(!argv || argc!=4)return 2;
  std::wstring executable=argv[1],config=argv[2],directory=argv[3];LocalFree(argv);
  SECURITY_ATTRIBUTES security{sizeof(security),nullptr,TRUE};
  auto file=[&](const wchar_t* name){return CreateFileW((directory+L"\\"+name).c_str(),GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);};
  HANDLE output=file(L"isolated-receiver-stdout.log"),error=file(L"isolated-receiver-stderr.log");
  HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,0,nullptr);
  HANDLE job=CreateJobObjectW(nullptr,nullptr);
  if(output==INVALID_HANDLE_VALUE || error==INVALID_HANDLE_VALUE || input==INVALID_HANDLE_VALUE || !job)return 2;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if(!SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limits,sizeof(limits)))return 2;
  SetEnvironmentVariableW(L"VIEWFLOW_ATLAS_TIMINGS",L"all");
  SetEnvironmentVariableW(L"VIEWFLOW_CLIPBOARD",L"0");
  SetEnvironmentVariableW(L"VIEWFLOW_ATLAS_PROGRESS_DIAGNOSTICS",L"1");
  SetEnvironmentVariableW(L"VIEWFLOW_QUIC_SOCKET_TRACE", L"1");
  SetEnvironmentVariableW(L"VIEWFLOW_ATLAS_GPU_QUERIES",L"0");
  STARTUPINFOW startup{sizeof(startup)};startup.dwFlags=STARTF_USESTDHANDLES|STARTF_USESHOWWINDOW;
  startup.wShowWindow=SW_HIDE;startup.hStdInput=input;startup.hStdOutput=output;startup.hStdError=error;
  std::wstring command=L"\""+executable+L"\" receive --config \""+config+L"\"";
  PROCESS_INFORMATION process{};
  if(!CreateProcessW(executable.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW|CREATE_SUSPENDED,nullptr,directory.c_str(),&startup,&process))return 2;
  if(!AssignProcessToJobObject(job,process.hProcess)){TerminateProcess(process.hProcess,2);return 2;}
  HANDLE status=file(L"isolated-runner-status.log");
  auto record=[&](const char* text){DWORD written=0;WriteFile(status,text,DWORD(strlen(text)),&written,nullptr);FlushFileBuffers(status);};
  char line[160];std::snprintf(line,sizeof(line),"runner_pid=%lu receiver_pid=%lu\n",GetCurrentProcessId(),process.dwProcessId);record(line);
  ResumeThread(process.hThread);CloseHandle(process.hThread);
  const DWORD waited=WaitForSingleObject(process.hProcess,90'000);
  if(waited!=WAIT_OBJECT_0){TerminateJobObject(job,ERROR_TIMEOUT);WaitForSingleObject(process.hProcess,5000);}
  DWORD code=1;GetExitCodeProcess(process.hProcess,&code);
  std::snprintf(line,sizeof(line),"receiver_exit=%lu watchdog=%u\n",code,unsigned(waited!=WAIT_OBJECT_0));record(line);
  CloseHandle(process.hProcess);CloseHandle(job);CloseHandle(input);CloseHandle(output);CloseHandle(error);CloseHandle(status);
  return waited==WAIT_OBJECT_0?int(code):124;
}
