// SPDX-License-Identifier: GPL-3.0-only
#include "window_renderer.hpp"
#include "capture_cadence.hpp"
#include "capture_commit_schedule.hpp"
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
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
#include <cstdio>
#include <vector>

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
struct CommitGroup;
struct Stream {
    std::unique_ptr<viewflow_capture::WindowRenderer> renderer;
    SP<CEventLoopTimer> timer;
    std::weak_ptr<CommitGroup> group;
    CHyprSignalListener commitListener;
    std::uint64_t address{}, sequence = 0;
    std::uint64_t commitNotifications = 0, commitAttempts = 0, fallbackAttempts = 0;
    unsigned fps{};
    bool commitMode = false;
    bool retired = false;
};
std::map<std::string, std::shared_ptr<Stream>> streams;
std::uint64_t nowNs() {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
struct CommitGroup : std::enable_shared_from_this<CommitGroup> {
    viewflow_capture::CaptureCommitSchedule schedule;
    SP<CEventLoopTimer> timer;
    std::map<std::string, std::weak_ptr<Stream>> members;
    explicit CommitGroup(unsigned fps) : schedule(fps) {}
    void arm() {
        const bool active = std::any_of(members.begin(), members.end(), [](const auto& entry) {
            const auto stream = entry.second.lock();
            return stream && !stream->retired;
        });
        if (active) timer->updateTimeout(std::chrono::nanoseconds(schedule.delay(nowNs())));
        else timer->updateTimeout(std::nullopt);
    }
    void notified() {
        schedule.committed();
        arm();
    }
    void tick() {
        const auto now = nowNs();
        if (!schedule.due(now)) { arm(); return; }
        const bool fromCommit = schedule.pending();
        schedule.attempted(now);
        // Freeze ownership before entering the renderer. Stop/removal cannot
        // invalidate a current attempt, and all equal-rate windows share a tick.
        std::vector<std::shared_ptr<Stream>> batch;
        for (const auto& [id, weak] : members)
            if (auto stream = weak.lock(); stream && !stream->retired) batch.push_back(std::move(stream));
        for (const auto& stream : batch) {
            if (stream->retired) continue;
            if (fromCommit) ++stream->commitAttempts;
            else ++stream->fallbackAttempts;
            if (!stream->renderer->capture(stream->address, ++stream->sequence)) {
                stream->retired = true;
                stream->commitListener.reset();
            }
        }
        arm();
    }
    void install() {
        const std::weak_ptr<CommitGroup> weak = shared_from_this();
        timer = makeShared<CEventLoopTimer>(std::chrono::nanoseconds(1),
            [weak](SP<CEventLoopTimer>, void*) {
                if (const auto group = weak.lock()) group->tick();
            }, nullptr);
        g_pEventLoopManager->addTimer(timer);
    }
};
std::map<unsigned, std::shared_ptr<CommitGroup>> groups;
void stopStream(const std::string& id, const std::shared_ptr<Stream>& stream) {
    stream->retired = true;
    stream->commitListener.reset();
    if (stream->timer) {
        stream->timer->updateTimeout(std::nullopt);
        g_pEventLoopManager->removeTimer(stream->timer);
    }
    if (const auto group = stream->group.lock()) {
        group->members.erase(id);
        if (group->members.empty()) {
            group->timer->updateTimeout(std::nullopt);
            g_pEventLoopManager->removeTimer(group->timer);
            groups.erase(stream->fps);
        } else group->arm();
    }
    std::fprintf(stderr, "viewflow-capture-cadence stop=1 stream=%s mode=%s fps=%u attempts=%llu notifications=%llu commit_attempts=%llu fallback_attempts=%llu\n",
        id.c_str(), stream->commitMode ? "commit" : "grid", stream->fps,
        static_cast<unsigned long long>(stream->sequence), static_cast<unsigned long long>(stream->commitNotifications),
        static_cast<unsigned long long>(stream->commitAttempts), static_cast<unsigned long long>(stream->fallbackAttempts));
}
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
int request(lua_State* state, bool stop, bool commitMode = false) {
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
            stopStream(id, found->second);
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
            auto stream = std::make_shared<Stream>();
            stream->address = target;
            stream->fps = fps;
            stream->commitMode = commitMode;
            stream->renderer = std::make_unique<viewflow_capture::WindowRenderer>(socket);
            try {
            if (commitMode) {
                auto found = groups.find(fps);
                auto group = found == groups.end() ? std::make_shared<CommitGroup>(fps) : found->second;
                if (found == groups.end()) {
                    group->install();
                    groups.emplace(fps, group);
                }
                stream->group = group;
                group->members.emplace(id, stream);
                const std::weak_ptr<Stream> weakStream = stream;
                const std::weak_ptr<CommitGroup> weakGroup = group;
                for (const auto& window : Desktop::windowState()->windows()) {
                    if (reinterpret_cast<std::uintptr_t>(window.get()) != target) continue;
                    if (window->wlSurface() && window->wlSurface()->resource()) {
                        stream->commitListener = window->wlSurface()->resource()->m_events.commit.listen(
                            [weakStream, weakGroup] {
                                const auto current = weakStream.lock();
                                const auto cohort = weakGroup.lock();
                                if (!current || current->retired || !cohort) return;
                                ++current->commitNotifications;
                                // Defer rendering to the timer; never re-enter
                                // the renderer from a wl_surface commit signal.
                                cohort->notified();
                            });
                    }
                    break;
                }
                group->arm();
            } else {
                const std::weak_ptr<Stream> weak = stream;
                stream->timer = makeShared<CEventLoopTimer>(captureDelay(fps),
                    [weak](SP<CEventLoopTimer> timer, void*) {
                        const auto owned = weak.lock();
                        if (!owned || owned->retired) { timer->updateTimeout(std::nullopt); return; }
                        ++owned->fallbackAttempts;
                        if (!owned->renderer->capture(owned->address, ++owned->sequence)) {
                            owned->retired = true;
                            timer->updateTimeout(std::nullopt);
                            return;
                        }
                        timer->updateTimeout(captureDelay(owned->fps));
                    }, nullptr);
                g_pEventLoopManager->addTimer(stream->timer);
            }
            file.reply({{"ok", true}, {"version", 1}, {"streamId", id}, {"socketPath", socket}, {"mode", "window-gpu"}});
            std::fprintf(stderr, "viewflow-capture-cadence start=1 stream=%s mode=%s fps=%u\n", id.c_str(), commitMode ? "commit" : "grid", fps);
            streams.emplace(id, stream);
            } catch (...) {
                // A failed reply/registration must not leave an expired member
                // blocking a later start with the same stream identity.
                stopStream(id, stream);
                throw;
            }
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
    if (!HyprlandAPI::addLuaFunction(handle, VIEWFLOW_CAPTURE_LUA_NAMESPACE, "window_stream_start", [](lua_State* s) { return request(s, false); })
        || !HyprlandAPI::addLuaFunction(handle, VIEWFLOW_CAPTURE_LUA_NAMESPACE, "window_stream_start_commit", [](lua_State* s) { return request(s, false, true); })
        || !HyprlandAPI::addLuaFunction(handle, VIEWFLOW_CAPTURE_LUA_NAMESPACE, "window_stream_stop", [](lua_State* s) { return request(s, true); }))
        throw std::runtime_error("Viewflow capture Lua registration failed");
    return {VIEWFLOW_CAPTURE_PLUGIN_NAME, "Window-only GPU capture for Viewflow", "Viewflow contributors", "0.1.0"};
}
APICALL EXPORT void PLUGIN_EXIT() {
    for (auto& [id, stream] : streams) {
        stopStream(id, stream);
    }
    streams.clear();
    groups.clear();
}
