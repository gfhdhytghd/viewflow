#pragma once
#include <windows.h>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <thread>

namespace viewflow::reverse::shm {
// A shorter non-spinning poll only while GPU readbacks are outstanding.
// Failure to create/arm/wait falls back locally to the existing sleep.
class ReadbackWait {
    HANDLE timer_{};unsigned microseconds_{};
public:
    static unsigned configured() {
        const auto* value=std::getenv("VIEWFLOW_SHM_POLL_US");
        if(value && std::strcmp(value,"250")==0)return 250;
        if(value && std::strcmp(value,"500")==0)return 500;
        return 0;
    }
    explicit ReadbackWait(unsigned microseconds=configured()):microseconds_(microseconds) {
        if(microseconds_==250 || microseconds_==500)
            timer_=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_MODIFY_STATE|SYNCHRONIZE);
    }
    ~ReadbackWait(){if(timer_)CloseHandle(timer_);}
    ReadbackWait(const ReadbackWait&)=delete;
    ReadbackWait& operator=(const ReadbackWait&)=delete;
    bool available()const{return timer_!=nullptr;}
    void pause(bool pending) {
        if(pending && timer_) {
            LARGE_INTEGER due{};due.QuadPart=-static_cast<LONGLONG>(microseconds_)*10;
            if(SetWaitableTimerEx(timer_,&due,0,nullptr,nullptr,nullptr,0) && WaitForSingleObject(timer_,100)==WAIT_OBJECT_0)return;
            CloseHandle(timer_);timer_=nullptr;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
};
}
