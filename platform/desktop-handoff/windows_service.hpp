#pragma once
// Same local-only v2 broker, SYSTEM/session check and identification-level
// impersonation as windows_input_service::Client. No elevated network endpoint.
#include "service_wire.hpp"
#include <aclapi.h>
namespace viewflow::handoff {
class ServiceClient {
    HANDLE pipe=INVALID_HANDLE_VALUE;
    void transfer(void* bytes,DWORD size,bool writing) {
        auto* p=static_cast<unsigned char*>(bytes);
        const auto started=GetTickCount64();
        while(size) {
            OVERLAPPED operation{};
            CursorHandle event(CreateEventW(nullptr,TRUE,FALSE,nullptr));
            if(!event.value)throw std::runtime_error("input service I/O event failed");
            operation.hEvent=event.value;DWORD count=0;
            BOOL ok=writing?WriteFile(pipe,p,size,&count,&operation):ReadFile(pipe,p,size,&count,&operation);
            if(!ok && GetLastError()==ERROR_IO_PENDING) {
                const auto elapsed=GetTickCount64()-started;
                DWORD result=WaitForSingleObject(event.value,elapsed>=5000?0:DWORD(5000-elapsed));
                if(result!=WAIT_OBJECT_0) {
                    CancelIoEx(pipe,&operation);
                    // OVERLAPPED storage remains alive until cancellation completes.
                    GetOverlappedResult(pipe,&operation,&count,TRUE);
                    throw std::runtime_error("input service operation timed out");
                }
                ok=GetOverlappedResult(pipe,&operation,&count,FALSE);
            }
            if(!ok || !count)throw std::runtime_error("input service connection lost");
            p+=count;size-=count;
        }
    }
public:
    ~ServiceClient(){close();}
    bool connected() const {return pipe!=INVALID_HANDLE_VALUE;}
    void close() noexcept {if(connected())CloseHandle(pipe);pipe=INVALID_HANDLE_VALUE;}
    bool connect() {
        close();
        DWORD session=0;
        if(!ProcessIdToSessionId(GetCurrentProcessId(),&session))return false;
        const auto name=L"\\\\.\\pipe\\ViewflowInput-v2-"+std::to_wstring(session);
        pipe=CreateFileW(name.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED|SECURITY_SQOS_PRESENT|SECURITY_IDENTIFICATION,nullptr);
        if(!connected())return false;
        // A standard (UAC-filtered) receiver cannot open the LocalSystem worker
        // process or its token. Verify the pipe object: only LocalSystem or an
        // elevated administrator can own it (LocalSystem's default owner is
        // BUILTIN\\Administrators).
        ULONG server_session=0;
        if(!GetNamedPipeServerSessionId(pipe,&server_session) || session!=server_session){close();return false;}
        PSID owner=nullptr;PSECURITY_DESCRIPTOR descriptor=nullptr;
        if(GetSecurityInfo(pipe,SE_KERNEL_OBJECT,OWNER_SECURITY_INFORMATION,&owner,nullptr,nullptr,nullptr,&descriptor)!=ERROR_SUCCESS){close();return false;}
        const bool trusted=IsWellKnownSid(owner,WinLocalSystemSid) || IsWellKnownSid(owner,WinBuiltinAdministratorsSid);
        LocalFree(descriptor);
        if(!trusted){close();return false;}
        return true;
    }
    void request(ServiceRequest request) {
        try {
            transfer(request.data(),DWORD(request.size()),true);
            std::array<unsigned char,5> reply{};transfer(reply.data(),DWORD(reply.size()),false);
            if(reply[0])throw std::runtime_error("input service rejected input or desktop unavailable");
        } catch(...) {close();throw;}
        // On uncertain delivery close, never reconnect/replay the same event.
        // The existing service releases its held state on pipe EOF.
    }
};
}
