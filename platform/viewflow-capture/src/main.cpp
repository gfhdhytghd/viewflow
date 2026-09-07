// SPDX-License-Identifier: GPL-3.0-only
#include "window_renderer.hpp"
#include "capture_cadence.hpp"
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <nlohmann/json.hpp>
extern "C" {
#include <lua.h>
}
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <charconv>
#include <filesystem>
#include <map>
#include <memory>
#include <stdexcept>

namespace {
using Json = nlohmann::json;
struct File {
    int fd = -1;
    explicit File(const char* path) {
        fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
        struct stat st{};
        if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid()
            || (st.st_mode & 077) || st.st_nlink != 1 || st.st_size <= 0 || st.st_size > 4096) {
            if (fd >= 0) close(fd);
            fd = -1;
            throw std::runtime_error("private request file required");
        }
    }
    ~File() { if (fd >= 0) close(fd); }
    Json read_json() {
        std::string value(4096, '\0');
        const auto count = read(fd, value.data(), value.size());
        if (count <= 0) throw std::runtime_error("request read failed");
        value.resize(count);
        return Json::parse(value);
    }
    void reply(const Json& value) {
        const auto data = value.dump();
        if (pwrite(fd, data.data(), data.size(), 0) != static_cast<ssize_t>(data.size())
            || ftruncate(fd, data.size())) throw std::runtime_error("response write failed");
    }
};
struct Stream {
    std::unique_ptr<viewflow_capture::WindowRenderer> renderer;
    SP<CEventLoopTimer> timer;
    std::uint64_t address{}, sequence = 0;
    unsigned fps{};
    bool retired = false;
};
std::map<std::string, std::unique_ptr<Stream>> streams;
std::chrono::nanoseconds captureDelay(unsigned fps) {
    const auto now = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    return std::chrono::nanoseconds(viewflow_capture::captureTickDelayNs(
        static_cast<std::uint64_t>(now), fps));
}
bool valid_id(const std::string& id) {
    return !id.empty() && id.size() <= 128 && std::all_of(id.begin(), id.end(), [](unsigned char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-';
    });
}
void socket_check(const std::string& path) {
    struct stat st{}, parent{};
    const auto dir = std::filesystem::path(path).parent_path();
    if (path.empty() || path.front() != '/' || path.size() >= 108 || path.find('\0') != std::string::npos
        || lstat(path.c_str(), &st) || !S_ISSOCK(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077)
        || lstat(dir.c_str(), &parent) || !S_ISDIR(parent.st_mode) || parent.st_uid != getuid() || (parent.st_mode & 077))
        throw std::runtime_error("private socket and directory required");
}
int request(lua_State* state, bool stop) {
    try {
        size_t length = 0;
        const char* path = lua_tolstring(state, 1, &length);
        if (!path || !length || length > 4096 || std::string_view(path, length).find('\0') != std::string_view::npos)
            throw std::runtime_error("request path required");
        File file(path);
        const auto data = file.read_json();
        if (stop) {
            const auto id = data.at("streamId").get<std::string>();
            const auto found = streams.find(id);
            if (found == streams.end()) throw std::runtime_error("unknown stream");
            // Auto-retired sessions retain exact identity until explicitly stopped.
            found->second->timer->updateTimeout(std::nullopt);
            g_pEventLoopManager->removeTimer(found->second->timer);
            streams.erase(found);
            file.reply({{"ok", true}, {"version", 1}, {"streamId", id}, {"stopped", true}});
        } else {
            const auto id = data.at("id").get<std::string>();
            const auto socket = data.at("socketPath").get<std::string>();
            const auto address = data.at("windowAddress").get<std::string>();
            const auto fps = data.at("fps").get<unsigned>();
            if (!valid_id(id) || streams.contains(id) || streams.size() >= 8 || data.at("mode") != "window-gpu"
                || fps < 1 || fps > 1000 || address.size() < 3 || address.size() > 18 || !address.starts_with("0x"))
                throw std::runtime_error("invalid stream request");
            std::uint64_t target = 0;
            const auto parsed = std::from_chars(address.data() + 2, address.data() + address.size(), target, 16);
            if (parsed.ec != std::errc{} || parsed.ptr != address.data() + address.size() || !target)
                throw std::runtime_error("invalid window address");
            socket_check(socket);
            auto stream = std::make_unique<Stream>();
            stream->address = target;
            stream->fps = fps;
            stream->renderer = std::make_unique<viewflow_capture::WindowRenderer>(socket);
            auto* owned = stream.get();
            stream->timer = makeShared<CEventLoopTimer>(captureDelay(fps),
                [owned](SP<CEventLoopTimer> timer, void*) {
                    if (!owned->renderer->capture(owned->address, ++owned->sequence)) {
                        owned->retired = true;
                        timer->updateTimeout(std::nullopt);
                        return;
                    }
                    timer->updateTimeout(captureDelay(owned->fps));
                }, nullptr);
            file.reply({{"ok", true}, {"version", 1}, {"streamId", id}, {"socketPath", socket}, {"mode", "window-gpu"}});
            g_pEventLoopManager->addTimer(stream->timer);
            streams.emplace(id, std::move(stream));
        }
        lua_pushboolean(state, true);
    } catch (const std::exception& error) {
        lua_pushboolean(state, false);
        lua_pushstring(state, error.what());
        return 2;
    }
    return 1;
}
}
APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }
APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    if (std::string_view(__hyprland_api_get_hash()) != std::string_view(__hyprland_api_get_client_hash()))
        throw std::runtime_error("Viewflow capture ABI mismatch");
    if (!HyprlandAPI::addLuaFunction(handle, "viewflow_capture", "window_stream_start", [](lua_State* s) { return request(s, false); })
        || !HyprlandAPI::addLuaFunction(handle, "viewflow_capture", "window_stream_stop", [](lua_State* s) { return request(s, true); }))
        throw std::runtime_error("Viewflow capture Lua registration failed");
    return {"viewflow-capture", "Window-only GPU capture for Viewflow", "Viewflow contributors", "0.1.0"};
}
APICALL EXPORT void PLUGIN_EXIT() {
    for (auto& [id, stream] : streams) {
        stream->timer->updateTimeout(std::nullopt);
        g_pEventLoopManager->removeTimer(stream->timer);
    }
    streams.clear();
}
