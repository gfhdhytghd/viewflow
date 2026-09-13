#pragma once
#include <atomic>
#include <cstdint>
#include <string>
#include <unistd.h>
#include <cstdlib>
namespace viewflow::reverse {
inline constexpr uint32_t backdrop_shm_magic = 0x56464248;
inline constexpr size_t backdrop_shm_pixels = 32u * 1024u * 1024u * 4u;
struct alignas(64) BackdropShm {
    uint32_t magic{}, pid{};
    uint64_t window{};
    alignas(64) std::atomic<uint64_t> sequence{0};
    uint32_t width{}, height{};
    int32_t x{}, y{}, logical_width{}, logical_height{}, window_x{}, window_y{};
    uint64_t timestamp_ns{};
};
inline constexpr size_t backdrop_shm_size = sizeof(BackdropShm) + backdrop_shm_pixels;
inline std::string backdrop_directory() {
    const char* runtime = std::getenv("XDG_RUNTIME_DIR");
    return std::string(runtime ? runtime : "/tmp") + "/viewflow/backdrops";
}
}
