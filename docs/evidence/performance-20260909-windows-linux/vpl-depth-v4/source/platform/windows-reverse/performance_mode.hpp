#pragma once
#include <algorithm>
#include <array>
#include <charconv>
#include <filesystem>
#include <fstream>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace viewflow::reverse {
enum class PerformanceMode { frame_rate, latency };

inline const char* mode_name(PerformanceMode mode) {
    return mode == PerformanceMode::latency ? "latency" : "frame-rate";
}

inline unsigned pending_limit(PerformanceMode mode) {
    return mode == PerformanceMode::latency ? 1u : 4u;
}

inline std::optional<PerformanceMode> parse_mode(std::string_view text) {
    const auto first = text.find_first_not_of(" \t\r\n");
    if (first == text.npos) return {};
    text = text.substr(first, text.find_last_not_of(" \t\r\n") - first + 1);
    if (text == "frame-rate") return PerformanceMode::frame_rate;
    if (text == "latency") return PerformanceMode::latency;
    return {};
}

// An absent, incomplete or invalid update retains the last applied mode.
// The controller replaces this small file atomically; no connection restart
// or cancellation of already submitted encoder/alpha work is required.
inline std::optional<PerformanceMode> read_mode(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) return {};
    std::array<char, 64> bytes{};
    file.read(bytes.data(), bytes.size());
    if (file.bad() || file.gcount() == static_cast<std::streamsize>(bytes.size())) return {};
    return parse_mode(std::string_view(bytes.data(), static_cast<std::size_t>(file.gcount())));
}

struct ReverseOptions {
    std::array<int, 4> bounds{-6144, -780, 0, 2676};
    PerformanceMode mode{PerformanceMode::frame_rate};
    std::filesystem::path mode_file;
    bool explicit_mode{};
    bool status_only{};
};

inline ReverseOptions parse_options(const std::vector<std::string_view>& arguments) {
    ReverseOptions options;
    std::vector<int> coordinates;
    bool explicit_file = false;
    for (std::size_t i = 0; i < arguments.size(); ++i) {
        const auto argument = arguments[i];
        if (argument == "--performance-status") {
            if (options.status_only) throw std::invalid_argument("duplicate reverse status option");
            options.status_only = true;
        } else if (argument == "--performance-mode" || argument == "--mode-file") {
            if (++i == arguments.size()) throw std::invalid_argument("missing reverse option value");
            if (argument == "--performance-mode") {
                const auto mode = parse_mode(arguments[i]);
                if (options.explicit_mode || !mode) throw std::invalid_argument("invalid reverse performance mode");
                options.mode = *mode;
                options.explicit_mode = true;
            } else {
                if (explicit_file || arguments[i].empty()) throw std::invalid_argument("invalid reverse mode file");
                options.mode_file = std::filesystem::path(std::string(arguments[i]));
                explicit_file = true;
            }
        } else {
            int coordinate{};
            const auto result = std::from_chars(argument.data(), argument.data() + argument.size(), coordinate);
            if (argument.empty() || result.ec != std::errc{} || result.ptr != argument.data() + argument.size())
                throw std::invalid_argument("invalid reverse coordinate or option");
            coordinates.push_back(coordinate);
        }
    }
    if (!coordinates.empty()) {
        if (coordinates.size() != 4) throw std::invalid_argument("reverse capture needs four coordinates");
        std::copy(coordinates.begin(), coordinates.end(), options.bounds.begin());
    }
    if (options.bounds[0] >= options.bounds[2] || options.bounds[1] >= options.bounds[3])
        throw std::invalid_argument("empty reverse capture rectangle");
    return options;
}
}
