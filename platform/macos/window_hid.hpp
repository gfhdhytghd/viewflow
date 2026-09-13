#pragma once
#include "../reverse-common/native_touchpad.hpp"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <deque>
#include <string>
#include <cstring>
#include <cstdio>
#include <cstdlib>

namespace viewflow::macos {
// Nonblocking local transport: a stalled HID host never blocks video or keys.
class WindowHID {
    int fd=-1;
    std::deque<std::uint8_t> pending;
    bool ending{};
    double retry_after{};
    std::uint64_t owner{};
    reverse::NativeTouchpadAssembler assembler;
    std::string path() const {
        const auto* home=getenv("HOME");
        return home?std::string(home)+"/Library/Application Support/Viewflow/run/hid.sock":"";
    }
    void close_stream() {
        if(fd>=0){shutdown(fd,SHUT_WR);::close(fd);fd=-1;}
        pending.clear();ending=false;owner=0;
    }
    void failed(double now) {
        std::fprintf(stderr,"window HID local transport unavailable: %s\n",std::strerror(errno));
        close_stream();assembler.reset();retry_after=now+1;
    }
public:
    ~WindowHID(){close_stream();}
    bool available(double now) const {
        struct stat st{}; const auto p=path();
        return now>=retry_after && !p.empty() && stat(p.c_str(),&st)==0 && S_ISSOCK(st.st_mode);
    }
    void drain(double now) {
        if(fd<0)return;
        // The host returns an exit code on failure; EOF is also a local failure.
        unsigned char reply[4]; const auto n=recv(fd,reply,sizeof(reply),MSG_PEEK|MSG_DONTWAIT);
        if(n>=0){errno=EPIPE;failed(now);return;}
        if(errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR){failed(now);return;}
        while(!pending.empty()) {
            std::array<std::uint8_t,1024> bytes{};
            const auto count=std::min(bytes.size(),pending.size());
            std::copy_n(pending.begin(),count,bytes.begin());
            const auto written=::write(fd,bytes.data(),count);
            if(written<0 && errno==EINTR)continue;
            if(written<0 && (errno==EAGAIN || errno==EWOULDBLOCK))return;
            if(written<=0){failed(now);return;}
            pending.erase(pending.begin(),pending.begin()+written);
        }
        if(ending)close_stream();
    }
    void release(std::uint64_t window) {
        if(!window || owner==window){close_stream();assembler.reset();}
    }
    void input(const reverse::Input& input,double now) {
        reverse::NativeTouchpadReport report{};
        if(!assembler.input(input,report))return;
        bool touching=false;
        for(unsigned i=0;i<report[0];++i)touching|=report[13+12*i]!=0;
        if(fd<0) {
            if(!touching || !available(now))return;
            const auto p=path();sockaddr_un address{};address.sun_family=AF_UNIX;
            if(p.size()>=sizeof(address.sun_path))return;
            std::memcpy(address.sun_path,p.c_str(),p.size()+1);
            fd=socket(AF_UNIX,SOCK_STREAM,0);
            if(fd<0){failed(now);return;}
            fcntl(fd,F_SETFD,FD_CLOEXEC);fcntl(fd,F_SETFL,O_NONBLOCK);
            const int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
            if(connect(fd,reinterpret_cast<sockaddr*>(&address),sizeof(address))<0){failed(now);return;}
            static constexpr std::array<std::uint8_t,8> header{'V','F','T','P',2,0,0,0};
            pending.insert(pending.end(),header.begin(),header.end());owner=input.id;
            std::fprintf(stderr,"window HID stream opened window=%llu\n",static_cast<unsigned long long>(owner));
        }
        if(owner!=input.id){release(0);return;}
        // Resource backlog recovery releases contacts locally; it does not end
        // the window session. Normal wheel routing resumes via capability bits.
        if(pending.size()>72*256){errno=ENOBUFS;failed(now);return;}
        pending.insert(pending.end(),report.begin(),report.end());
        ending=!touching;drain(now);
    }
};
}
