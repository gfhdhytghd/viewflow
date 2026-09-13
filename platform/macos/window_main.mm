#include "window_native.hpp"
#include "window_codec.hpp"
#include "window_pixels.hpp"
#include "window_parking.hpp"
#include <charconv>
#include <csignal>
#include <cstdio>
#include <string_view>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <thread>
#include <cerrno>
#include <mach-o/dyld.h>
#import <Foundation/Foundation.h>

static std::atomic<bool> owner_disconnected{false};
bool viewflow::macos::transport_owner_alive() { return !owner_disconnected.load(); }

// Like the app's source capture helpers, each background-capturing presenter
// needs its own executable path. replayd otherwise replaces concurrent clients
// when an inventory probe or a second presenter opens the same helper path.
struct PresenterExecutable {
    NSString* directory=nil;
    PresenterExecutable(int argc,const char* argv[]) {
        int mode=1;
        while(mode+1<argc&&(std::string_view(argv[mode])=="--owner-pid"||std::string_view(argv[mode])=="--owner-pid-file"))mode+=2;
        bool presenter=mode<argc&&std::string_view(argv[mode])=="present",validate=false;
        for(int i=mode+1;i<argc;++i)validate|=std::string_view(argv[i])=="--validate";
        if(!presenter||validate)return;
        uint32_t size=0;_NSGetExecutablePath(nullptr,&size);
        std::vector<char> path(size);
        if(_NSGetExecutablePath(path.data(),&size)!=0)return;
        if(const char* isolated=std::getenv("VIEWFLOW_PRESENTER_EXECUTABLE")) {
            if(std::string_view(isolated)==path.data()) {
                NSString* candidate=[@(isolated) stringByDeletingLastPathComponent];
                if([candidate.lastPathComponent hasPrefix:@"viewflow-presenter-"]&&
                    [[candidate.stringByDeletingLastPathComponent stringByStandardizingPath] isEqualToString:[NSTemporaryDirectory() stringByStandardizingPath]]) {
                    directory=candidate;return;
                }
            }
        }
        std::string pattern=[NSTemporaryDirectory() stringByAppendingPathComponent:@"viewflow-presenter-XXXXXX"].UTF8String;
        std::vector<char> temporary(pattern.begin(),pattern.end());temporary.push_back(0);
        if(!mkdtemp(temporary.data()))throw std::runtime_error("create presenter capture directory");
        directory=@(temporary.data());
        NSString* executable=[directory stringByAppendingPathComponent:@"viewflow-macos-windows"];
        NSError* error=nil;
        if(![[NSFileManager defaultManager] copyItemAtPath:@(path.data()) toPath:executable error:&error]) {
            [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
            throw std::runtime_error(error.localizedDescription.UTF8String);
        }
        setenv("VIEWFLOW_PRESENTER_EXECUTABLE",executable.fileSystemRepresentation,1);
        std::vector<char*> arguments;
        arguments.push_back(const_cast<char*>(executable.fileSystemRepresentation));
        for(int i=1;i<argc;++i)arguments.push_back(const_cast<char*>(argv[i]));
        arguments.push_back(nullptr);
        execv(executable.fileSystemRepresentation,arguments.data());
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        throw std::runtime_error("execute isolated presenter capture helper");
    }
    ~PresenterExecutable() {
        if(directory)[[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
    }
};

static constexpr auto usage =
    "Usage: viewflow-macos-windows source --window ID [--window ID ...] [--scale 1|2] [--fps 1..120] [--codec h264|hevc] [--native-decorations 0|1]\n"
    "       viewflow-macos-windows present [--scale 1|2] [--origin-x POINTS] [--origin-y POINTS] [--performance-mode frame-rate|latency] [--linux-shortcut RULE ...] [--validate]\n"
    "       viewflow-macos-windows --performance-status [frame-rate|latency]\n"
    "       viewflow-macos-windows --codec-self-test\n"
    "       viewflow-macos-windows --permissions | --list-windows\n"
    "       viewflow-macos-windows --write-fixture PATH\n"
    "Media/input records use stdin/stdout; launch through vf-window-peer. Diagnostics use stderr.\n";

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        std::signal(SIGPIPE, SIG_IGN);
        try {
            PresenterExecutable isolated(argc,argv);
            if (argc >= 3 && std::string_view(argv[1]) == "--owner-pid") {
                const std::string_view text = argv[2];
                int owner = 0;
                const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), owner);
                if (error != std::errc{} || end != text.data() + text.size() || owner <= 1)
                    throw std::runtime_error("invalid transport owner pid");
                std::thread([owner] {
                    while (::kill(owner, 0) == 0 || errno == EPERM)
                        std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    owner_disconnected = true;
                    // The main loop releases input and stops capture first.
                    // A vanished transport owner must not leave a launchd-owned
                    // process indefinitely waiting for a broken OS callback.
                    std::this_thread::sleep_for(std::chrono::seconds(10));
                    std::raise(SIGTERM);
                }).detach();
                argc -= 2; argv += 2;
            }
            // Launch Services reparents apps to launchd. Report this exact
            // instance so its stdio adapter can reap it after disconnection.
            if (argc >= 3 && std::string_view(argv[1]) == "--owner-pid-file") {
                FILE* file = std::fopen(argv[2], "w");
                if (!file) throw std::runtime_error("cannot write owner pid file");
                std::fprintf(file, "%d\n", getpid());
                std::fclose(file);
                argc -= 2; argv += 2;
            }
            if (argc == 6 && std::string_view(argv[1]) == "--parking-display") {
                int values[4]{};
                for (int i = 0; i < 4; ++i) {
                    const std::string_view text = argv[i+2];
                    const auto [end, error] = std::from_chars(text.data(), text.data()+text.size(), values[i]);
                    if (error != std::errc{} || end != text.data()+text.size()) throw std::runtime_error("invalid virtual display geometry");
                }
                if (values[0] < 64 || values[1] < 64 || values[0] > 8192 || values[1] > 8192 ||
                    values[2] < -100000 || values[2] > 100000 || values[3] < -100000 || values[3] > 100000)
                    throw std::runtime_error("virtual display geometry unsupported");
                return viewflow::macos::run_parking_display(values[0], values[1], values[2], values[3]);
            }
            if (argc == 2 && std::string_view(argv[1]) == "--help") { std::puts(usage); return 0; }
            if (argc == 2 && (std::string_view(argv[1]) == "--permissions" || std::string_view(argv[1]) == "--list-windows"))
                return viewflow::macos::discover_windows(std::string_view(argv[1]) == "--list-windows");
            if (argc == 2 && std::string_view(argv[1]) == "--codec-self-test") {
                viewflow::macos::codec_self_test(); viewflow::macos::pixel_self_test(); return 0;
            }
            if (argc == 2 && std::string_view(argv[1]) == "--presenter-self-test") {
                viewflow::macos::presenter_self_test(); return 0;
            }
            if ((argc == 2 || argc == 3) && std::string_view(argv[1]) == "--performance-status") {
                const std::string_view mode = argc == 3 ? argv[2] : "frame-rate";
                if (mode != "frame-rate" && mode != "latency") throw std::runtime_error("invalid performance mode");
                std::printf("performance_mode=%.*s source_queue_depth=%u presenter_drawables=%u\n",
                    int(mode.size()), mode.data(), 3u, mode == "latency" ? 2u : 3u);
                return 0;
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
                if (name == "--performance-mode") {
                    if (value != "frame-rate" && value != "latency") throw std::runtime_error("invalid performance mode");
                    options.performance_mode = value == "latency" ? viewflow::macos::PerformanceMode::latency
                                                                   : viewflow::macos::PerformanceMode::frame_rate;
                    continue;
                }
                if (name == "--linux-shortcut" && !options.source) {
                    options.linux_shortcuts.emplace_back(value); continue;
                }
                if (name == "--evidence-dir" && !options.source) {
                    options.evidence_dir=value;continue;
                }
                int number = 0;
                const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), number);
                if (error != std::errc{} || end != value.data() + value.size()) throw std::runtime_error("invalid integer option");
                if (name == "--window" && options.source && number > 0) options.windows.push_back(static_cast<unsigned>(number));
                else if (name == "--scale" && number >= 1 && number <= 4) options.scale = number;
                else if (name == "--native-decorations" && options.source && (number == 0 || number == 1)) options.native_decorations = number;
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
