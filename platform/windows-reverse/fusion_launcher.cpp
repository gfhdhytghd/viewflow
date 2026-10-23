#include <windows.h>
#include <string>
// A GUI-subsystem supervisor prevents Windows Terminal console delegation.
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR arguments,int) {
    wchar_t system[MAX_PATH]{};GetSystemDirectoryW(system,MAX_PATH);
    std::wstring exe=std::wstring(system)+L"\\WindowsPowerShell\\v1.0\\powershell.exe";
    std::wstring command=L"\""+exe+L"\" -NoProfile -NonInteractive -ExecutionPolicy Bypass "+arguments;
    STARTUPINFOW startup{};startup.cb=sizeof(startup);
    PROCESS_INFORMATION process{};
    HANDLE job=CreateJobObjectW(nullptr,nullptr);
    if(!job)return GetLastError();
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit{};
    limit.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if(!SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limit,sizeof(limit))){auto error=GetLastError();CloseHandle(job);return error;}
    if(!CreateProcessW(exe.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW|CREATE_SUSPENDED,nullptr,nullptr,&startup,&process)){auto error=GetLastError();CloseHandle(job);return error;}
    if(!AssignProcessToJobObject(job,process.hProcess)){auto error=GetLastError();TerminateProcess(process.hProcess,error);CloseHandle(process.hThread);CloseHandle(process.hProcess);CloseHandle(job);return error;}
    ResumeThread(process.hThread);
    CloseHandle(process.hThread);WaitForSingleObject(process.hProcess,INFINITE);
    DWORD result{};GetExitCodeProcess(process.hProcess,&result);CloseHandle(process.hProcess);CloseHandle(job);return result;
}
