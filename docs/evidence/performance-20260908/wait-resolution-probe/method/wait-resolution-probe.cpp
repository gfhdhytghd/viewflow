// No windows or input. All policy changes target this short-lived process.
#include <windows.h>
#include <mmsystem.h>
#include <shellapi.h>
#include <cstdio>
#include <vector>
#include <cstdint>
struct Sample {unsigned block,mode,index;LONGLONG begin,end;DWORD result;};
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
  int argc=0;auto args=CommandLineToArgvW(GetCommandLineW(),&argc);
  if(!args||argc!=2)return 2;
  FILE* log{};_wfopen_s(&log,args[1],L"w");LocalFree(args);if(!log)return 3;
  const HWND foreground=GetForegroundWindow();
  LARGE_INTEGER frequency{};QueryPerformanceFrequency(&frequency);
  PROCESS_POWER_THROTTLING_STATE original{PROCESS_POWER_THROTTLING_CURRENT_VERSION};
  if(!GetProcessInformation(GetCurrentProcess(),ProcessPowerThrottling,&original,sizeof(original))) {
    std::fprintf(log,"get_policy_error=%lu\n",GetLastError());std::fclose(log);return 4;
  }
  const MMRESULT period=timeBeginPeriod(1);
  std::fprintf(log,"probe pid=%lu qpc_frequency=%lld period_result=%u original_control=%lu original_state=%lu\n",GetCurrentProcessId(),frequency.QuadPart,period,original.ControlMask,original.StateMask);
  HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr);
  HANDLE timer=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_MODIFY_STATE|SYNCHRONIZE);
  if(!event||!timer||period!=TIMERR_NOERROR) {
    std::fprintf(log,"initialization_error=%lu\n",GetLastError());
    if(event)CloseHandle(event);if(timer)CloseHandle(timer);if(period==TIMERR_NOERROR)timeEndPeriod(1);std::fclose(log);return 5;
  }
  std::vector<Sample> samples;samples.reserve(2048);
  const unsigned order[]{0,1,2,3,3,2,1,0};
  int exit=0;
  for(unsigned block=0;block<8 && !exit;++block) {
    const unsigned mode=order[block];
    auto policy=original;
    if(mode&1) {
      policy.ControlMask|=PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION;
      policy.StateMask&=~PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION;
    }
    if(!SetProcessInformation(GetCurrentProcess(),ProcessPowerThrottling,&policy,sizeof(policy))) {
      std::fprintf(log,"set_policy_error=%lu block=%u\n",GetLastError(),block);exit=6;break;
    }
    PROCESS_POWER_THROTTLING_STATE readback{PROCESS_POWER_THROTTLING_CURRENT_VERSION};
    if(!GetProcessInformation(GetCurrentProcess(),ProcessPowerThrottling,&readback,sizeof(readback)) ||
       readback.ControlMask!=policy.ControlMask || readback.StateMask!=policy.StateMask) {
      std::fprintf(log,"policy_readback_failed block=%u\n",block);exit=7;break;
    }
    std::fprintf(log,"block=%u mode=%u policy_control=%lu policy_state=%lu high_resolution=%u honor_resolution=%u\n",block,mode,readback.ControlMask,readback.StateMask,unsigned(mode&2)!=0,unsigned(mode&1)!=0);
    for(unsigned i=0;i<256;++i) {
      LARGE_INTEGER begin{},end{},due{};due.QuadPart=-10000; // relative 1 ms
      QueryPerformanceCounter(&begin);
      if((mode&2) && !SetWaitableTimerEx(timer,&due,0,nullptr,nullptr,nullptr,0)) {exit=8;break;}
      const DWORD result=WaitForSingleObject((mode&2)?timer:event,(mode&2)?INFINITE:1);
      QueryPerformanceCounter(&end);samples.push_back({block,mode,i,begin.QuadPart,end.QuadPart,result});
      if(result!=((mode&2)?WAIT_OBJECT_0:WAIT_TIMEOUT)){exit=9;break;}
    }
  }
  const BOOL restored=SetProcessInformation(GetCurrentProcess(),ProcessPowerThrottling,&original,sizeof(original));
  PROCESS_POWER_THROTTLING_STATE final{PROCESS_POWER_THROTTLING_CURRENT_VERSION};
  const BOOL read=GetProcessInformation(GetCurrentProcess(),ProcessPowerThrottling,&final,sizeof(final));
  const bool same=restored && read && final.ControlMask==original.ControlMask && final.StateMask==original.StateMask;
  for(const auto& s:samples)std::fprintf(log,"sample block=%u mode=%u index=%u begin=%lld end=%lld result=%lu\n",s.block,s.mode,s.index,s.begin,s.end,s.result);
  std::fprintf(log,"result samples=%zu restored=%u foreground_unchanged=%u exit=%d\n",samples.size(),unsigned(same),unsigned(GetForegroundWindow()==foreground),exit);
  CancelWaitableTimer(timer);CloseHandle(timer);CloseHandle(event);timeEndPeriod(1);std::fclose(log);
  return same?exit:10;
}
