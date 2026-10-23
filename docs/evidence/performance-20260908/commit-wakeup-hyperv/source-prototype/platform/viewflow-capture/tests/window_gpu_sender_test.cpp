// SPDX-License-Identifier: GPL-3.0-only
// Derived from HyprCapture caa7657c5f13b5828f984357f7686c98375f2949; see ../NOTICE.
#include "window_gpu_sender.hpp"
#include "window_gpu_wire.hpp"

#include <array>
#include <atomic>
#include <memory>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <thread>
#include <string>
#include <unistd.h>

using namespace std::chrono_literals;
using viewflow_capture::WindowGpuPacket;
using viewflow_capture::WindowGpuSender;
using viewflow_capture::WindowGpuSenderState;
using viewflow_capture::gpuwire::Frame;

namespace {
enum class ServerMode { Ack, AckInput, DelayedAck, NoAck, Disconnect, AncillaryRelease, WrongSequence, WrongEpoch, ReservedRelease };

struct Server {
    char directory[64] = "/tmp/hcgf-sender-XXXXXX";
    std::string path;
    ServerMode mode;
    std::thread thread;
    std::atomic<bool> received{false};
    std::atomic<bool> twoFds{false};
    std::atomic<int> frameCount{0};

    explicit Server(ServerMode m) : mode(m) {
        assert(mkdtemp(directory));
        chmod(directory, 0700);
        path = std::string(directory) + "/s";
        thread = std::thread([this] { run(); });
        std::this_thread::sleep_for(500ms); // let the bounded test listener bind before sender connect
    }
    ~Server() { if (thread.joinable()) thread.join(); unlink(path.c_str()); rmdir(directory); }

    void run() {
        int listener = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0); assert(listener >= 0);
        sockaddr_un address{}; address.sun_family = AF_UNIX; std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
        assert(bind(listener, reinterpret_cast<sockaddr*>(&address), static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + path.size() + 1)) == 0);
        assert(listen(listener, 1) == 0);
        int fd = accept(listener, nullptr, nullptr); assert(fd >= 0); close(listener);
        for (int iteration = 0; iteration < (mode == ServerMode::Ack || mode == ServerMode::AckInput || mode == ServerMode::DelayedAck ? 2 : 1); ++iteration) {
        std::array<unsigned char, 320> header{}; std::array<unsigned char, CMSG_SPACE(2 * sizeof(int))> control{};
        iovec io{header.data(), header.size()}; msghdr msg{}; msg.msg_iov=&io; msg.msg_iovlen=1; msg.msg_control=control.data(); msg.msg_controllen=control.size();
        const auto n = recvmsg(fd, &msg, 0); assert(n == (mode == ServerMode::AckInput ? 320 : 232)); assert(!(msg.msg_flags & (MSG_TRUNC|MSG_CTRUNC))); ++frameCount;
        if (mode == ServerMode::AckInput) {
            viewflow_capture::gpuwire::InputGeometry input;
            assert(viewflow_capture::gpuwire::decode(header.data() + 232, 88, input));
            assert(input.window == 0x1234 && input.surface == 0x5678 && input.pid == 9012);
        }
        int count=0;
        for (auto* c=CMSG_FIRSTHDR(&msg); c; c=CMSG_NXTHDR(&msg,c)) if(c->cmsg_level==SOL_SOCKET&&c->cmsg_type==SCM_RIGHTS){auto bytes=c->cmsg_len-CMSG_LEN(0);for(size_t off=0;off+sizeof(int)<=bytes;off+=sizeof(int)){int receivedFd;std::memcpy(&receivedFd,CMSG_DATA(c)+off,sizeof(receivedFd));assert(fcntl(receivedFd,F_GETFD)>=0);close(receivedFd);++count;}}
        received=true; twoFds=(count==2);
        if (mode == ServerMode::Disconnect) { close(fd); return; }
        if (mode == ServerMode::NoAck) { std::this_thread::sleep_for(700ms); close(fd); return; }
        if (mode == ServerMode::DelayedAck) std::this_thread::sleep_for(700ms);
        std::array<unsigned char,32> reply{}; std::memcpy(reply.data(),"HCGR",4); reply[5]=1; reply[7]=32; std::memcpy(reply.data()+8,header.data()+8,8); std::memcpy(reply.data()+16,header.data()+24,8);
        if (mode == ServerMode::WrongSequence) reply[15] ^= 1;
        if (mode == ServerMode::WrongEpoch) reply[23] ^= 1;
        if (mode == ServerMode::ReservedRelease) reply[31] = 1;
        iovec rio{reply.data(),reply.size()}; msghdr out{}; out.msg_iov=&rio;out.msg_iovlen=1;
        if(mode==ServerMode::AncillaryRelease){std::array<unsigned char,CMSG_SPACE(sizeof(int))> c{};out.msg_control=c.data();out.msg_controllen=c.size();auto* h=CMSG_FIRSTHDR(&out);h->cmsg_level=SOL_SOCKET;h->cmsg_type=SCM_RIGHTS;h->cmsg_len=CMSG_LEN(sizeof(int));int extra=open("/dev/null",O_RDONLY);std::memcpy(CMSG_DATA(h),&extra,sizeof(extra));assert(sendmsg(fd,&out,MSG_NOSIGNAL)==32);close(extra);}
        else assert(sendmsg(fd,&out,MSG_NOSIGNAL)==32);
        }
        // Keep the peer connected long enough that rejection is due to the
        // malformed record, not merely POLLHUP racing the read.
        std::this_thread::sleep_for(100ms);
        close(fd);
    }
};

bool waitState(WindowGpuSender& sender, WindowGpuSenderState state, int ms=1200){for(int i=0;i<ms/5;i++){if(sender.state()==state)return true;std::this_thread::sleep_for(5ms);}return sender.state()==state;}
void expectNotification(WindowGpuSender& sender) {
    assert(sender.notificationFd() >= 0);
    assert(fcntl(sender.notificationFd(), F_GETFD) & FD_CLOEXEC);
    assert(fcntl(sender.notificationFd(), F_GETFL) & O_NONBLOCK);
    pollfd fd{sender.notificationFd(), POLLIN, 0};
    assert(poll(&fd, 1, 1000) == 1 && (fd.revents & POLLIN));
    sender.drainNotifications();
    assert(poll(&fd, 1, 0) == 0);
}
void expectState(WindowGpuSender& sender, WindowGpuSenderState state, const char* label) {
    if (!waitState(sender, state)) {
        std::fprintf(stderr, "state wait failed: %s got=%d want=%d\n", label,
                     int(sender.state()), int(state));
        std::abort();
    }
}
Frame metadata(std::uint64_t sequence, std::uint64_t epoch){Frame f{};f.sequence=sequence;f.captureMonotonicNs=100+sequence;f.geometryEpoch=epoch;f.logicalWidth=2;f.logicalHeight=2;f.imageWidth=2;f.imageHeight=2;f.stride=8;f.cropWidth=2;f.cropHeight=2;f.shadowEnabled=false;return f;}
WindowGpuPacket packet(const Frame& f,int& image,int& fence){WindowGpuPacket p{};assert(viewflow_capture::gpuwire::encode(f,p.header));image=open("/dev/null",O_RDONLY);fence=open("/dev/null",O_RDONLY);assert(image>=0&&fence>=0);p.imageFd=image;p.fenceFd=fence;return p;}
void assertClosed(int fd){errno=0;assert(fcntl(fd,F_GETFD)==-1&&errno==EBADF);}
}

int main(){
    { Server server(ServerMode::DelayedAck); WindowGpuSender sender(server.path);
      expectState(sender, WindowGpuSenderState::Ready, "delayed initial");
      int image, fence; assert(sender.submit(packet(metadata(1,1), image, fence)));
      for (int i=0; i<100 && !server.received; ++i) std::this_thread::sleep_for(5ms);
      assert(server.received);
      std::this_thread::sleep_for(600ms);
      assert(sender.state() == WindowGpuSenderState::Busy);
      assert(fcntl(image,F_GETFD)>=0 && fcntl(fence,F_GETFD)>=0);
      int blockedImage, blockedFence; auto blocked=packet(metadata(2,1), blockedImage, blockedFence);
      assert(!sender.submit(std::move(blocked))); // One allocation remains outstanding.
      blocked=WindowGpuPacket{};
      expectState(sender, WindowGpuSenderState::Ready, "delayed released");
      assertClosed(image); assertClosed(fence);
      assert(sender.submit(packet(metadata(2,1), image, fence)));
      expectState(sender, WindowGpuSenderState::Ready, "delayed next frame");
      assert(server.frameCount==2);
    }

    { Server server(ServerMode::AckInput); WindowGpuSender sender(server.path);
      expectState(sender, WindowGpuSenderState::Ready, "input initial");
      for (std::uint64_t sequence : {1, 2}) {
        int a, b; auto p = packet(metadata(sequence, 1), a, b);
        p.inputGeometry.emplace();
        assert(viewflow_capture::gpuwire::encode(
            viewflow_capture::gpuwire::InputGeometry{0x1234, 0x5678, 9012, {0, 0, 2, 2}, {2, 2}}, *p.inputGeometry));
        auto bad = packet(metadata(sequence, 1), a, b);
        bad.inputGeometry = p.inputGeometry; (*bad.inputGeometry)[87] = 1;
        assert(!sender.submit(std::move(bad)));
        WindowGpuPacket moved; moved = std::move(p);
        assert(sender.submit(std::move(moved)));
        expectState(sender, WindowGpuSenderState::Ready, "input ack");
      }
      assert(server.frameCount == 2 && server.twoFds);
    }
    { Server server(ServerMode::Ack); WindowGpuSender sender(server.path);
      expectState(sender, WindowGpuSenderState::Ready, "ack initial");
      expectNotification(sender); assert(sender.lastReleaseUs() == 0);
      int a,b; auto p=packet(metadata(1,2),a,b); assert(sender.submit(std::move(p))); assert(sender.state()==WindowGpuSenderState::Busy);
      int c,d; auto second=packet(metadata(2,1),c,d); assert(!sender.submit(std::move(second))); second=WindowGpuPacket{}; assertClosed(c); assertClosed(d);
      expectState(sender, WindowGpuSenderState::Ready, "ack first"); expectNotification(sender); assert(sender.lastReleaseUs() > 0); assertClosed(a); assertClosed(b);
      int badImage,badFence; auto bad=packet(metadata(3,2),badImage,badFence); bad.header[116]=1; assert(!sender.submit(std::move(bad))); bad=WindowGpuPacket{}; assertClosed(badImage); assertClosed(badFence);
      int oldSeqImage,oldSeqFence; auto oldSeq=packet(metadata(1,1),oldSeqImage,oldSeqFence); assert(!sender.submit(std::move(oldSeq))); oldSeq=WindowGpuPacket{}; assertClosed(oldSeqImage); assertClosed(oldSeqFence);
      int oldEpochImage,oldEpochFence; auto oldEpoch=packet(metadata(3,1),oldEpochImage,oldEpochFence); assert(!sender.submit(std::move(oldEpoch))); oldEpoch=WindowGpuPacket{}; assertClosed(oldEpochImage); assertClosed(oldEpochFence);
      int e,f; assert(sender.submit(packet(metadata(2,2),e,f))); if (!waitState(sender, WindowGpuSenderState::Ready)) { std::fprintf(stderr, "ack second diagnostic state=%d frames=%d received=%d two=%d\n", int(sender.state()), server.frameCount.load(), int(server.received), int(server.twoFds)); std::abort(); } assert(server.received&&server.twoFds); }
    { Server server(ServerMode::NoAck); WindowGpuSender sender(server.path); expectState(sender,WindowGpuSenderState::Ready,"noack initial");int a,b;assert(sender.submit(packet(metadata(1,1),a,b)));expectState(sender,WindowGpuSenderState::Retired,"noack retire");assertClosed(a);assertClosed(b);int c,d;auto reuse=packet(metadata(2,1),c,d);assert(!sender.submit(std::move(reuse)));reuse=WindowGpuPacket{};assertClosed(c);assertClosed(d); }
    { Server server(ServerMode::AncillaryRelease); WindowGpuSender sender(server.path); expectState(sender,WindowGpuSenderState::Ready,"ancillary initial");int a,b;assert(sender.submit(packet(metadata(1,1),a,b)));expectState(sender,WindowGpuSenderState::Retired,"ancillary retire");assertClosed(a);assertClosed(b); }
    { Server server(ServerMode::Disconnect); WindowGpuSender sender(server.path); expectState(sender,WindowGpuSenderState::Ready,"disconnect initial");int a,b;assert(sender.submit(packet(metadata(1,1),a,b)));expectState(sender,WindowGpuSenderState::Retired,"disconnect retire");assertClosed(a);assertClosed(b); }
    for (auto mode : {ServerMode::WrongSequence, ServerMode::WrongEpoch, ServerMode::ReservedRelease}) {
        Server server(mode); WindowGpuSender sender(server.path);
        expectState(sender, WindowGpuSenderState::Ready, "bad release initial");
        int image, fence;
        assert(sender.submit(packet(metadata(1, 1), image, fence)));
        expectState(sender, WindowGpuSenderState::Retired, "bad release retired");
        expectNotification(sender);
        assertClosed(image); assertClosed(fence);
    }
    { Server server(ServerMode::NoAck);
      auto sender = std::make_unique<WindowGpuSender>(server.path);
      expectState(*sender, WindowGpuSenderState::Ready, "stop initial");
      const int eventFd = sender->notificationFd();
      int image, fence; assert(sender->submit(packet(metadata(1, 1), image, fence)));
      for (int i = 0; i < 100 && !server.received.load(); ++i) std::this_thread::sleep_for(5ms);
      assert(server.received.load());
      const auto before = std::chrono::steady_clock::now();
      sender.reset();
      assert(std::chrono::steady_clock::now() - before < 100ms);
      assertClosed(eventFd); assertClosed(image); assertClosed(fence);
    }
    std::puts("PASS window GPU sender bounded ACK/retire/FD ownership suite");
}
