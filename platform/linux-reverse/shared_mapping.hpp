#pragma once
#include "../reverse-common/shared_frames.hpp"
#include "../reverse-common/dma_bank_layout.hpp"
#include <nlohmann/json.hpp>
#include <sys/mman.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/ioctl.h>
#if __has_include(<linux/udmabuf.h>)
#include <linux/udmabuf.h>
#define VIEWFLOW_HAVE_UDMABUF_HEADER 1
#endif
#include <fcntl.h>
#include <unistd.h>
#include <cstdlib>
#include <string>

namespace viewflow::reverse::shm {
class Mapping {
    struct Fd {
        int value=-1;
        ~Fd(){if(value>=0)close(value);}
    };
    struct Region {
        int fd=-1;void* data=MAP_FAILED;std::size_t size{};
        ~Region(){if(data!=MAP_FAILED)munmap(data,size);if(fd>=0)close(fd);}
        void map(std::size_t minimum,bool exclusive) {
            struct stat st{};
            if(fstat(fd,&st) || st.st_size<0 || std::uint64_t(st.st_size)<minimum ||
               (exclusive && flock(fd,LOCK_EX|LOCK_NB)))
                throw std::runtime_error("IVSHMEM host size or reader ownership");
            size=st.st_size;data=mmap(nullptr,size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
            if(data==MAP_FAILED)throw std::runtime_error("cannot map IVSHMEM host file");
        }
        void open_file(const char* path,std::size_t minimum) {
            fd=open(path,O_RDWR|O_CLOEXEC);
            if(fd<0)throw std::runtime_error("cannot open IVSHMEM host file");
            map(minimum,true);
        }
    } control_,banks_[slots];
    struct Export { Fd fd;std::uint64_t size{}; };
    struct ExportLease { std::shared_ptr<Export> exported;std::shared_ptr<Mapping> mapping; };
    std::array<std::shared_ptr<Export>,slots> exports_{};
    DmaBankLayout dma_layout_{};
    BankLayout bank_layout_{};
    bool memfd_{};
    std::size_t capacity_{};
    bool unchanged() const noexcept {
        return !std::memcmp(&bank_layout_,static_cast<const char*>(control_.data)+bank_layout_offset,sizeof(bank_layout_)) &&
               !std::memcmp(&dma_layout_,static_cast<const char*>(control_.data)+dma_bank_layout_offset,offsetof(DmaBankLayout,requested));
    }
    void open_broker() {
        std::memcpy(&dma_layout_,static_cast<const char*>(control_.data)+dma_bank_layout_offset,offsetof(DmaBankLayout,requested));
        if(!valid_dma_bank_layout(dma_layout_) || capacity_!=dma_layout_.capacity)
            throw std::runtime_error("invalid DMA bank descriptor");
        const char* path=std::getenv("VIEWFLOW_DMA_BANK_SOCKET");
        if(!path || !*path)path="/run/viewflow-dma-banks.sock";
        sockaddr_un address{};address.sun_family=AF_UNIX;
        if(std::strlen(path)>=sizeof(address.sun_path))throw std::runtime_error("DMA broker socket path too long");
        std::strcpy(address.sun_path,path);
        Fd socket_fd;socket_fd.value=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0);
        if(socket_fd.value<0)throw std::runtime_error("cannot create DMA broker socket");
        timeval timeout{2,0};
        setsockopt(socket_fd.value,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        setsockopt(socket_fd.value,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
        if(connect(socket_fd.value,reinterpret_cast<sockaddr*>(&address),sizeof(address)) ||
           send(socket_fd.value,"GET\n",4,MSG_NOSIGNAL)!=4)
            throw std::runtime_error("cannot connect DMA bank broker");
        std::array<Fd,slots> received;unsigned count=0;std::string response;
        for(;;) {
            char bytes[4096];alignas(cmsghdr) char ancillary[CMSG_SPACE(sizeof(int)*32)]{};
            iovec io{bytes,sizeof(bytes)};msghdr message{};
            message.msg_iov=&io;message.msg_iovlen=1;message.msg_control=ancillary;message.msg_controllen=sizeof(ancillary);
            auto n=recvmsg(socket_fd.value,&message,MSG_CMSG_CLOEXEC);
            if(n<=0)throw std::runtime_error("truncated DMA bank broker response");
            bool extra=false;
            for(auto* c=CMSG_FIRSTHDR(&message);c;c=CMSG_NXTHDR(&message,c)) {
                if(c->cmsg_level!=SOL_SOCKET || c->cmsg_type!=SCM_RIGHTS)continue;
                const auto total=(c->cmsg_len-CMSG_LEN(0))/sizeof(int);
                const auto* fds=reinterpret_cast<const int*>(CMSG_DATA(c));
                for(std::size_t i=0;i<total;++i) {
                    if(count<slots)received[count++].value=fds[i];else {close(fds[i]);extra=true;}
                }
            }
            if(extra || (message.msg_flags&(MSG_TRUNC|MSG_CTRUNC)))throw std::runtime_error("invalid DMA broker descriptors");
            response.append(bytes,n);
            if(response.size()>4096)throw std::runtime_error("oversized DMA broker response");
            if(response.find('\n')!=std::string::npos)break;
        }
        const auto metadata=nlohmann::json::parse(response);
        if(count!=slots || metadata.at("version")!=2 || metadata.at("generation")!=dma_layout_.generation ||
           metadata.at("capacity")!=capacity_ || metadata.at("devices").size()!=slots || metadata.at("inodes").size()!=slots)
            throw std::runtime_error("DMA broker identity mismatch");
        for(unsigned i=0;i<slots;++i) {
            struct stat st{};const auto fd=received[i].value;
            const int seals=fcntl(fd,F_GET_SEALS);
            if(fstat(fd,&st) || !S_ISREG(st.st_mode) || std::uint64_t(st.st_size)!=capacity_ ||
               seals<0 || (seals&(F_SEAL_WRITE|0x0010 /* F_SEAL_FUTURE_WRITE */)) ||
               (seals&(F_SEAL_GROW|F_SEAL_SHRINK))!=(F_SEAL_GROW|F_SEAL_SHRINK) ||
               (fcntl(fd,F_GETFL)&O_ACCMODE)!=O_RDWR ||
               std::uint64_t(st.st_dev)!=dma_layout_.bank_devices[i] || std::uint64_t(st.st_ino)!=dma_layout_.bank_inodes[i] ||
               metadata.at("devices").at(i)!=std::uint64_t(st.st_dev) || metadata.at("inodes").at(i)!=std::uint64_t(st.st_ino) ||
               metadata.at("owner_uid")!=st.st_uid)
                throw std::runtime_error("DMA broker bank validation failed");
            banks_[i].fd=fd;received[i].value=-1;banks_[i].map(capacity_,false);
        }
        if(!unchanged())throw std::runtime_error("DMA bank descriptor changed during connection");
        memfd_=true;
    }
public:
    Mapping(const char* path) {
        control_.open_file(path,header_bytes);
        std::memcpy(&bank_layout_,static_cast<std::uint8_t*>(control_.data)+bank_layout_offset,sizeof(bank_layout_));
        if(bank_layout_.magic==bank_magic) {
            if(bank_layout_.capacity<4096 || bank_layout_.capacity>max_slot_bytes || bank_layout_.capacity%64)
                throw std::runtime_error("IVSHMEM bank capacity");
            capacity_=bank_layout_.capacity;
            if(bank_layout_.reserved&bank_memfd)open_broker();
            else for(unsigned i=0;i<slots;++i)banks_[i].open_file((std::string(path)+".slot"+std::to_string(i)).c_str(),capacity_);
        }
        frames().recover(false);frames().reader_ready(true);
    }
    ~Mapping(){frames().reader_ready(false);}
    Mapping(const Mapping&)=delete;Mapping& operator=(const Mapping&)=delete;
    bool supports_dma_buffers() const noexcept {
#ifdef VIEWFLOW_HAVE_UDMABUF_HEADER
        return memfd_ && unchanged();
#else
        return false;
#endif
    }
    std::shared_ptr<SharedDmaBuffer> dma_buffer(unsigned slot,std::uint32_t width,std::uint32_t height,
                                              const std::shared_ptr<Mapping>& owner) noexcept {
#ifndef VIEWFLOW_HAVE_UDMABUF_HEADER
        (void)slot;(void)width;(void)height;(void)owner;return {};
#else
        try {
            if(owner.get()!=this || !supports_dma_buffers() || slot>=slots || !width || !height || width>16384 || height>16384)return {};
            const auto bytes=std::uint64_t(width)*height*4;
            const auto page=sysconf(_SC_PAGESIZE);if(page<=0)return {};
            const auto extent=(bytes+page-1)/page*page;if(extent>capacity_)return {};
            auto exported=exports_[slot];
            if(!exported || exported->size!=extent) {
                Fd device;device.value=open("/dev/udmabuf",O_RDWR|O_CLOEXEC);if(device.value<0)return {};
                udmabuf_create request{};request.memfd=banks_[slot].fd;request.flags=UDMABUF_FLAGS_CLOEXEC;request.size=extent;
                exported=std::make_shared<Export>();exported->fd.value=ioctl(device.value,UDMABUF_CREATE,&request);
                if(exported->fd.value<0)return {};
                exported->size=extent;exports_[slot]=exported;
            }
            auto result=std::make_shared<SharedDmaBuffer>();result->fd=exported->fd.value;result->pitch=width*4;
            result->owner=std::make_shared<ExportLease>(ExportLease{exported,owner});return result;
        } catch(...) {return {};}
#endif
    }
    Frames frames(){
        if(!capacity_)return Frames(control_.data,control_.size);
        std::array<void*,slots> banks{};for(unsigned i=0;i<slots;++i)banks[i]=banks_[i].data;
        return Frames(control_.data,control_.size,banks,capacity_);
    }
};
}
