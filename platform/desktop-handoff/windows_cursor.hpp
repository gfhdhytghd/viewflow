#pragma once
// Included after windows.h. ShowCursor is input-queue scoped and cannot reliably
// hide the desktop cursor from this background hook worker. Replace the system
// cursor images while owning one session-local mutex; reload the user's cursor
// scheme on release. No persistent cursor scheme/registry setting is changed.
#include <array>
#include <cstdio>
#include <string>
#include <stdexcept>
namespace viewflow::handoff {
struct CursorHandle {
    HANDLE value{};
    explicit CursorHandle(HANDLE h=nullptr):value(h){}
    ~CursorHandle(){if(value)CloseHandle(value);}
    CursorHandle(const CursorHandle&)=delete;
    CursorHandle& operator=(const CursorHandle&)=delete;
};
inline constexpr auto cursor_mutex=L"Local\\ViewflowHandoffCursorVisibility";
inline std::wstring cursor_event(DWORD pid,const wchar_t* suffix) {
    return L"Local\\ViewflowHandoffCursor-"+std::to_wstring(pid)+suffix;
}
inline bool acquire_cursor(HANDLE mutex) {
    const DWORD r=WaitForSingleObject(mutex,0);
    return r==WAIT_OBJECT_0 || r==WAIT_ABANDONED;
}
// Event-driven recovery: waits for the adapter process, never polls input.
// The dirty event survives its owner because this guardian keeps a handle.
inline int cursor_guard(DWORD pid) {
    CursorHandle process(OpenProcess(SYNCHRONIZE,FALSE,pid));
    CursorHandle mutex(OpenMutexW(SYNCHRONIZE|MUTEX_MODIFY_STATE,FALSE,cursor_mutex));
    CursorHandle dirty(OpenEventW(SYNCHRONIZE|EVENT_MODIFY_STATE,FALSE,cursor_event(pid,L"-dirty").c_str()));
    CursorHandle ready(OpenEventW(EVENT_MODIFY_STATE,FALSE,cursor_event(pid,L"-ready").c_str()));
    if(!process.value || !mutex.value || !dirty.value || !ready.value)return 1;
    SetEvent(ready.value);
    if(WaitForSingleObject(process.value,INFINITE)!=WAIT_OBJECT_0)return 1;
    if(WaitForSingleObject(dirty.value,0)==WAIT_OBJECT_0 && acquire_cursor(mutex.value)) {
        // Another worker may already own the mutex. Never reveal its cursor.
        SystemParametersInfoW(SPI_SETCURSORS,0,nullptr,0);
        ClipCursor(nullptr);
        ResetEvent(dirty.value);ReleaseMutex(mutex.value);
    }
    return 0;
}
class CursorVisibility {
    CursorHandle mutex,dirty,ready;
    bool owned{};
public:
    CursorVisibility():mutex(CreateMutexW(nullptr,FALSE,cursor_mutex)),
        dirty(CreateEventW(nullptr,TRUE,FALSE,cursor_event(GetCurrentProcessId(),L"-dirty").c_str())),
        ready(CreateEventW(nullptr,TRUE,FALSE,cursor_event(GetCurrentProcessId(),L"-ready").c_str())) {
        if(!mutex.value || !dirty.value || !ready.value)throw std::runtime_error("cursor recovery handles unavailable");
        // Also repairs a previous run if both the adapter and its guardian were
        // forcibly killed (for example by a job-object teardown). A live owner
        // holds the mutex, so starting another link never makes it visible.
        if(acquire_cursor(mutex.value)) {
            const bool ok=SystemParametersInfoW(SPI_SETCURSORS,0,nullptr,0)!=FALSE;
            ReleaseMutex(mutex.value);
            if(!ok)throw std::runtime_error("restore desktop cursor scheme failed");
        }
        std::array<wchar_t,32768> path{};
        const DWORD n=GetModuleFileNameW(nullptr,path.data(),DWORD(path.size()));
        if(!n || n>=path.size())throw std::runtime_error("cursor guardian executable path unavailable");
        std::wstring command=L"\""+std::wstring(path.data(),n)+L"\" --cursor-guard "+std::to_wstring(GetCurrentProcessId());
        STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION child{};
        // No inherited stdio handles: a guardian must never keep native stdin or
        // stdout alive after the adapter dies.
        if(!CreateProcessW(path.data(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child))
            throw std::runtime_error("cursor guardian start failed");
        CursorHandle process(child.hProcess),thread(child.hThread);
        if(WaitForSingleObject(ready.value,5000)!=WAIT_OBJECT_0) {
            TerminateProcess(process.value,1);
            throw std::runtime_error("cursor guardian startup timed out");
        }
    }
    ~CursorVisibility() {
        restore();
        // If restoration failed because the desktop disappeared, leave the
        // dirty event set for the guardian's final attempt after process exit.
        if(owned)ReleaseMutex(mutex.value);
    }
    void hide() {
        if(owned)return;
        if(!acquire_cursor(mutex.value))throw std::runtime_error("desktop cursor already owned");
        owned=true;SetEvent(dirty.value);
        std::array<unsigned char,128> and_mask,xor_mask{};and_mask.fill(0xff);
        for(DWORD id:{OCR_NORMAL,OCR_IBEAM,OCR_WAIT,OCR_CROSS,OCR_UP,OCR_SIZENWSE,
            OCR_SIZENESW,OCR_SIZEWE,OCR_SIZENS,OCR_SIZEALL,OCR_NO,OCR_HAND,OCR_APPSTARTING,OCR_HELP}) {
            HCURSOR cursor=CreateCursor(GetModuleHandleW(nullptr),0,0,32,32,and_mask.data(),xor_mask.data());
            if(!cursor) {restore();throw std::runtime_error("transparent desktop cursor creation failed");}
            // SetSystemCursor consumes the cursor on success.
            if(!SetSystemCursor(cursor,id)) {
                DestroyCursor(cursor);restore();throw std::runtime_error("hide desktop cursor failed");
            }
        }
        std::fprintf(stderr,"handoff cursor hidden\n");
    }
    bool restore() noexcept {
        if(!owned)return true;
        if(!SystemParametersInfoW(SPI_SETCURSORS,0,nullptr,0))return false;
        ResetEvent(dirty.value);ReleaseMutex(mutex.value);owned=false;
        std::fprintf(stderr,"handoff cursor restored\n");return true;
    }
};
}
