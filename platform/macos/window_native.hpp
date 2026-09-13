#pragma once
#include "../reverse-common/wire.hpp"
#include <string>
#include <vector>

namespace viewflow::macos {
enum class PerformanceMode { frame_rate, latency };
struct Options {
    bool source{};
    bool validate{};
    bool native_decorations{};
    unsigned codec{1}, fps{60};
    double scale{1};
    int origin_x{}, origin_y{};
    PerformanceMode performance_mode{PerformanceMode::frame_rate};
    std::vector<unsigned> windows;
    std::vector<std::string> linux_shortcuts;
    std::string evidence_dir;
};
int run_source(const Options&);
int run_presenter(const Options&);
bool transport_owner_alive();
void presenter_self_test();
int discover_windows(bool enumerate);
}
