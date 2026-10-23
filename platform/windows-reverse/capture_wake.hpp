#pragma once
#include <windows.h>
#include <cstdlib>
#include <cstring>
namespace viewflow::reverse::shm {
// Auto-reset notification coalesces captures and retains a notification that
// arrives before the sender waits. It does not override lane pacing/budgets.
class CaptureWake {
    HANDLE event_{};
public:
    static bool configured(){const auto* v=std::getenv("VIEWFLOW_SHM_CAPTURE_WAKE");return v && std::strcmp(v,"1")==0;}
    explicit CaptureWake(bool enabled=configured()){if(enabled)event_=CreateEventW(nullptr,FALSE,FALSE,nullptr);}
    ~CaptureWake(){if(event_)CloseHandle(event_);}
    CaptureWake(const CaptureWake&)=delete;
    CaptureWake& operator=(const CaptureWake&)=delete;
    void notify()const{if(event_)SetEvent(event_);}
    DWORD wait(DWORD timeout=1)const{return event_?WaitForSingleObject(event_,timeout):WAIT_FAILED;}
};
}
