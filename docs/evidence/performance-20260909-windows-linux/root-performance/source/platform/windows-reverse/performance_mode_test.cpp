#include "performance_mode.hpp"
#include <cassert>
#include <chrono>

using namespace viewflow::reverse;
int main() {
    const auto legacy = parse_options({"-6144", "-780", "0", "2676"});
    assert((legacy.bounds == std::array{-6144, -780, 0, 2676}));
    assert(legacy.mode == PerformanceMode::frame_rate && !legacy.explicit_mode);
    const auto selected = parse_options({"--mode-file", "settings/mode", "-6144", "-780", "0", "2676", "--performance-mode", "latency"});
    assert(selected.bounds == legacy.bounds && selected.mode == PerformanceMode::latency && selected.explicit_mode);
    assert(selected.mode_file == std::filesystem::path("settings/mode"));
    assert(parse_options({"--performance-status", "--mode-file", "settings/mode"}).status_only);
    for (const std::vector<std::string_view>& bad : {
            std::vector<std::string_view>{"--performance-mode"}, {"--performance-mode", "fast"},
            {"--mode-file", ""}, {"0", "0", "0", "10"}, {"-1", "0", "10"},
            {"-6144x", "-780", "0", "2676"}, {"999999999999999999999999"},
            {"--performance-mode", "latency", "--performance-mode", "frame-rate"},
            {"--unknown"}}) {
        bool rejected = false;
        try { parse_options(bad); } catch (const std::invalid_argument&) { rejected = true; }
        assert(rejected);
    }
    assert(pending_limit(PerformanceMode::frame_rate) == 4 && pending_limit(PerformanceMode::latency) == 1);
    const auto file = std::filesystem::temp_directory_path() / ("viewflow-mode-test-" +
        std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    assert(!read_mode(file));
    for (const auto text : {"", "lat", "invalid", "latency\nframe-rate", "                                                               latency"}) {
        { std::ofstream out(file); out << text; }
        assert(!read_mode(file));
    }
    { std::ofstream out(file); out << "latency\r\n"; }
    assert(read_mode(file) == PerformanceMode::latency);
    { std::ofstream out(file); out << "frame-rate\n"; }
    assert(read_mode(file) == PerformanceMode::frame_rate);
    std::filesystem::remove(file);
}
