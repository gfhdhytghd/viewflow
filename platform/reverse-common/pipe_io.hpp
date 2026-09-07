#pragma once
#include "wire.hpp"
#include <cerrno>
#include <cstdio>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif
namespace viewflow::reverse {
inline bool read_exact(int fd, void* data, std::size_t size) {
    auto* p = static_cast<uint8_t*>(data);
    while (size) {
#ifdef _WIN32
        const auto count = ::_read(fd, p, static_cast<unsigned>(std::min(size, std::size_t(1 << 20))));
#else
        const auto count = ::read(fd, p, size);
#endif
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        p += count; size -= count;
    }
    return true;
}
inline bool read_record(int fd, std::vector<uint8_t>& bytes) {
    uint8_t prefix[4];
    if (!read_exact(fd, prefix, sizeof(prefix))) return false;
    Reader reader{prefix};
    const auto count = reader.u32();
    if (count < 4 || count > max_record) throw std::runtime_error("invalid window record length");
    bytes.resize(count);
    if (!read_exact(fd, bytes.data(), count)) throw std::runtime_error("truncated window record");
    return true;
}
inline void write_exact(int fd, std::span<const uint8_t> bytes) {
    while (!bytes.empty()) {
#ifdef _WIN32
        const auto count = ::_write(fd, bytes.data(), static_cast<unsigned>(std::min(bytes.size(), std::size_t(1 << 20))));
#else
        const auto count = ::write(fd, bytes.data(), bytes.size());
#endif
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) throw std::runtime_error("window output pipe closed");
        bytes = bytes.subspan(count);
    }
}
inline void write_record(int fd, std::span<const uint8_t> bytes) {
    if (bytes.size() > max_record) throw std::runtime_error("window record too large");
    Writer prefix; prefix.u32(static_cast<uint32_t>(bytes.size()));
    write_exact(fd, prefix.bytes); write_exact(fd, bytes);
}
}
