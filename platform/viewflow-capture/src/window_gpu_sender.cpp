// SPDX-License-Identifier: GPL-3.0-only
// Derived from HyprCapture caa7657c5f13b5828f984357f7686c98375f2949; see ../NOTICE.
#include "window_gpu_sender.hpp"
#include "window_gpu_wire.hpp"
#include <cerrno>
#include <chrono>
#include <cstring>
#include <poll.h>
#include <sys/socket.h>
#include <sys/eventfd.h>
#include <sys/un.h>
#include <unistd.h>
#include <utility>

namespace viewflow_capture {
namespace {
struct Fd {
    int value;
    ~Fd() { if (value >= 0) close(value); }
};
using Clock = std::chrono::steady_clock;
bool waitSocket(int fd, short events, Clock::time_point deadline, std::stop_token stop) {
    while (!stop.stop_requested() && Clock::now() < deadline) {
        pollfd p{fd, events, 0};
        const int result = poll(&p, 1, 5);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || (p.revents & (POLLERR | POLLHUP | POLLNVAL))) return false;
        if (result > 0 && (p.revents & events)) return true;
    }
    return false;
}
bool releaseMatches(int fd, const WindowGpuPacket& frame) {
    std::array<unsigned char, 32> reply{};
    alignas(cmsghdr) std::array<unsigned char, CMSG_SPACE(8 * sizeof(int))> control{};
    iovec io{reply.data(), reply.size()};
    msghdr message{};
    message.msg_iov = &io; message.msg_iovlen = 1;
    message.msg_control = control.data(); message.msg_controllen = control.size();
    const auto count = recvmsg(fd, &message, MSG_CMSG_CLOEXEC);
    bool ancillary = false;
    for (auto* c = CMSG_FIRSTHDR(&message); c; c = CMSG_NXTHDR(&message, c)) {
        ancillary = true;
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS && c->cmsg_len >= CMSG_LEN(0)) {
            const auto bytes = c->cmsg_len - CMSG_LEN(0);
            for (size_t offset = 0; offset + sizeof(int) <= bytes; offset += sizeof(int)) {
                int received = -1;
                std::memcpy(&received, CMSG_DATA(c) + offset, sizeof(received));
                if (received >= 0) close(received);
            }
        }
    }
    if (count != 32 || ancillary || (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC))) return false;
    constexpr unsigned char prefix[]{'H','C','G','R',0,1,0,32};
    if (std::memcmp(reply.data(), prefix, 8) != 0 ||
        std::memcmp(reply.data() + 8, frame.header.data() + 8, 8) != 0 ||
        std::memcmp(reply.data() + 16, frame.header.data() + 24, 8) != 0) return false;
    for (size_t i = 24; i < reply.size(); ++i) if (reply[i] != 0) return false;
    return true;
}
bool sendFrame(int fd, const WindowGpuPacket& frame) {
    std::array<iovec, 2> io{{
        {const_cast<unsigned char*>(frame.header.data()), frame.header.size()},
        {frame.inputGeometry ? const_cast<unsigned char*>(frame.inputGeometry->data()) : nullptr,
         frame.inputGeometry ? frame.inputGeometry->size() : 0}
    }};
    alignas(cmsghdr) std::array<unsigned char, CMSG_SPACE(2 * sizeof(int))> control{};
    msghdr message{};
    message.msg_iov = io.data(); message.msg_iovlen = frame.inputGeometry ? 2 : 1;
    message.msg_control = control.data(); message.msg_controllen = control.size();
    auto* c = CMSG_FIRSTHDR(&message);
    c->cmsg_level = SOL_SOCKET; c->cmsg_type = SCM_RIGHTS; c->cmsg_len = CMSG_LEN(2 * sizeof(int));
    const int descriptors[]{frame.imageFd, frame.fenceFd};
    std::memcpy(CMSG_DATA(c), descriptors, sizeof(descriptors));
    return sendmsg(fd, &message, MSG_NOSIGNAL) == static_cast<ssize_t>(io[0].iov_len + io[1].iov_len);
}
} // namespace

WindowGpuPacket::~WindowGpuPacket() {
    if (imageFd >= 0) close(imageFd);
    if (fenceFd >= 0 && fenceFd != imageFd) close(fenceFd);
}
WindowGpuPacket::WindowGpuPacket(WindowGpuPacket&& other) noexcept
    : header(other.header), inputGeometry(std::move(other.inputGeometry)), imageFd(std::exchange(other.imageFd, -1)), fenceFd(std::exchange(other.fenceFd, -1)) {}
WindowGpuPacket& WindowGpuPacket::operator=(WindowGpuPacket&& other) noexcept {
    if (this != &other) {
        if (imageFd >= 0) close(imageFd);
        if (fenceFd >= 0 && fenceFd != imageFd) close(fenceFd);
        header = other.header;
        inputGeometry = std::move(other.inputGeometry);
        imageFd = std::exchange(other.imageFd, -1);
        fenceFd = std::exchange(other.fenceFd, -1);
    }
    return *this;
}
WindowGpuSender::WindowGpuSender(std::string path)
    : m_path(std::move(path)), m_notificationFd(eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC)),
      m_worker([this](std::stop_token stop) { run(stop); }) {}
WindowGpuSender::~WindowGpuSender() {
    m_worker.request_stop();
    m_wake.notify_all();
    if (m_worker.joinable()) m_worker.join();
    if (m_notificationFd >= 0) close(m_notificationFd);
}
void WindowGpuSender::notify() noexcept {
    const std::uint64_t value = 1;
    // EAGAIN means an earlier notification is already waiting in the loop.
    while (write(m_notificationFd, &value, sizeof(value)) < 0 && errno == EINTR) {}
}
void WindowGpuSender::drainNotifications() noexcept {
    std::uint64_t value;
    while (read(m_notificationFd, &value, sizeof(value)) < 0 && errno == EINTR) {}
}
bool WindowGpuSender::submit(WindowGpuPacket&& packet) noexcept {
    gpuwire::Frame metadata;
    if (packet.imageFd < 0 || packet.fenceFd < 0 || packet.imageFd == packet.fenceFd ||
        !gpuwire::decode(packet.header.data(), packet.header.size(), metadata)) return false;
    gpuwire::InputGeometry input;
    if (packet.inputGeometry && !gpuwire::decode(packet.inputGeometry->data(), packet.inputGeometry->size(), input)) return false;
    std::unique_lock lock(m_mutex, std::try_to_lock);
    if (!lock.owns_lock() || state() != WindowGpuSenderState::Ready || m_pending) return false;
    if (metadata.sequence <= m_lastSequence || metadata.geometryEpoch < m_lastEpoch) return false;
    m_lastSequence = metadata.sequence;
    m_lastEpoch = metadata.geometryEpoch;
    m_pending.emplace(std::move(packet));
    m_state.store(WindowGpuSenderState::Busy, std::memory_order_release);
    lock.unlock();
    m_wake.notify_one();
    return true;
}
void WindowGpuSender::run(std::stop_token stop) {
    struct Retire {
        WindowGpuSender& sender;
        ~Retire() {
            sender.m_state.store(WindowGpuSenderState::Retired, std::memory_order_release);
            sender.notify();
        }
    } retire{*this};
    if (m_notificationFd < 0) return;
    sockaddr_un address{};
    if (m_path.empty() || m_path.size() >= sizeof(address.sun_path) || m_path.find('\0') != std::string::npos) return;
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, m_path.c_str(), m_path.size() + 1);
    Fd socket{::socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0)};
    if (socket.value < 0) return;
    const int connected = connect(socket.value, reinterpret_cast<sockaddr*>(&address),
                                  static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + m_path.size() + 1));
    if (connected != 0) {
        if (errno != EINPROGRESS || !waitSocket(socket.value, POLLOUT, Clock::now() + std::chrono::milliseconds(250), stop)) return;
        int error = 0; socklen_t length = sizeof(error);
        if (getsockopt(socket.value, SOL_SOCKET, SO_ERROR, &error, &length) != 0 || error != 0) return;
    }
    ucred peer{}; socklen_t length = sizeof(peer);
    if (getsockopt(socket.value, SOL_SOCKET, SO_PEERCRED, &peer, &length) != 0 ||
        length != sizeof(peer) || peer.uid != getuid() || peer.pid <= 0) return;
    m_state.store(WindowGpuSenderState::Ready, std::memory_order_release);
    notify();
    while (!stop.stop_requested()) {
        std::optional<WindowGpuPacket> frame;
        {
            std::unique_lock lock(m_mutex);
            if (!m_wake.wait(lock, stop, [this] { return m_pending.has_value(); })) return;
            frame = std::move(m_pending); m_pending.reset();
        }
        if (!frame || !sendFrame(socket.value, *frame)) return;
        // Input recovery and native WM loops may pause the consumer. Keep this
        // sole outstanding allocation until its exact release, peer disconnect,
        // or explicit stop; a stalled consumer cannot queue additional frames.
        if (!waitSocket(socket.value, POLLIN, Clock::time_point::max(), stop) ||
            !releaseMatches(socket.value, *frame)) return;
        frame.reset();
        m_lastReleaseUs.store(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now().time_since_epoch()).count(), std::memory_order_release);
        m_state.store(WindowGpuSenderState::Ready, std::memory_order_release);
        notify();
    }
}
} // namespace viewflow_capture
