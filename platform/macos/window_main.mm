#include "window_native.hpp"
#include "window_codec.hpp"
#include "window_pixels.hpp"
#include <charconv>
#include <csignal>
#include <cstdio>
#include <string_view>
#import <Foundation/Foundation.h>

static constexpr auto usage =
    "Usage: viewflow-macos-windows source --window ID [--window ID ...] [--scale 1|2] [--fps 1..120] [--codec h264|hevc]\n"
    "       viewflow-macos-windows present [--scale 1|2] [--origin-x POINTS] [--origin-y POINTS] [--validate]\n"
    "       viewflow-macos-windows --codec-self-test\n"
    "       viewflow-macos-windows --write-fixture PATH\n"
    "Media/input records use stdin/stdout; launch through vf-window-peer. Diagnostics use stderr.\n";

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        std::signal(SIGPIPE, SIG_IGN);
        try {
            if (argc == 2 && std::string_view(argv[1]) == "--help") { std::puts(usage); return 0; }
            if (argc == 2 && std::string_view(argv[1]) == "--codec-self-test") {
                viewflow::macos::codec_self_test(); viewflow::macos::pixel_self_test(); return 0;
            }
            if (argc == 3 && std::string_view(argv[1]) == "--write-fixture") {
                viewflow::macos::codec_self_test(argv[2]); return 0;
            }
            if (argc < 2 || (std::string_view(argv[1]) != "source" && std::string_view(argv[1]) != "present"))
                throw std::runtime_error(usage);
            viewflow::macos::Options options;
            options.source = std::string_view(argv[1]) == "source";
            for (int i = 2; i < argc; i += 2) {
                if (std::string_view(argv[i]) == "--validate" && !options.source) { options.validate = true; --i; continue; }
                if (i + 1 == argc) throw std::runtime_error("missing option value");
                const std::string_view name = argv[i], value = argv[i + 1];
                if (name == "--codec") {
                    if (value != "h264" && value != "hevc") throw std::runtime_error("invalid codec");
                    options.codec = value == "h264" ? 1 : 2; continue;
                }
                int number = 0;
                const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), number);
                if (error != std::errc{} || end != value.data() + value.size()) throw std::runtime_error("invalid integer option");
                if (name == "--window" && options.source && number > 0) options.windows.push_back(static_cast<unsigned>(number));
                else if (name == "--scale" && number >= 1 && number <= 4) options.scale = number;
                else if (name == "--fps" && number >= 1 && number <= 120) options.fps = static_cast<unsigned>(number);
                else if (name == "--origin-x") options.origin_x = number;
                else if (name == "--origin-y") options.origin_y = number;
                else throw std::runtime_error("invalid option or value");
            }
            if (options.source && (options.windows.empty() || options.windows.size() > 32))
                throw std::runtime_error("source requires 1..32 selected window IDs");
            return options.source ? viewflow::macos::run_source(options) : viewflow::macos::run_presenter(options);
        } catch (const std::exception& error) {
            std::fprintf(stderr, "macos windows: %s\n", error.what()); return 1;
        }
    }
}
