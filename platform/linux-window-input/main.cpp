#include "../reverse-common/pipe_io.hpp"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <unistd.h>
#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstring>
#include <set>
#include <string>

namespace vf = viewflow::reverse;
namespace {
std::string ipc(const std::string& command) {
    const char* runtime = getenv("XDG_RUNTIME_DIR"), *signature = getenv("HYPRLAND_INSTANCE_SIGNATURE");
    if (!runtime || !signature) throw std::runtime_error("missing Hyprland session environment");
    const auto path = std::string(runtime) + "/hypr/" + signature + "/.socket.sock";
    sockaddr_un address{}; address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) throw std::runtime_error("Hyprland IPC path too long");
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) throw std::runtime_error("create Hyprland IPC socket");
    const timeval timeout{5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    std::string result;
    try {
        if (connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0) throw std::runtime_error("connect Hyprland IPC");
        vf::write_exact(fd, {reinterpret_cast<const uint8_t*>(command.data()), command.size()});
        char bytes[4096];
        for (;;) {
            const auto count = ::read(fd, bytes, sizeof(bytes));
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) throw std::runtime_error("read Hyprland IPC");
            if (!count) break;
            result.append(bytes, static_cast<size_t>(count));
            if (result.size() > 65536) throw std::runtime_error("Hyprland IPC reply too large");
        }
    } catch (...) { close(fd); throw; }
    close(fd); return result;
}
struct App {
    wl_display* display{};
    wl_registry* registry{};
    wl_seat* seat{};
    wl_keyboard* physical{};
    zwlr_virtual_pointer_manager_v1* pointer_manager{};
    zwp_virtual_keyboard_manager_v1* keyboard_manager{};
    zwlr_virtual_pointer_v1* pointer{};
    zwp_virtual_keyboard_v1* keyboard{};
    xkb_context* context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    xkb_keymap* map{};
    xkb_state* state{};
    std::set<uint32_t> held_keys, held_buttons;
    std::string address, stable_id;
    std::string keymap_text;
    unsigned pid{};
    uint64_t sequence{};
    int32_t pointer_x{}, pointer_y{};
    bool has_pointer{};
    ~App() {
        try { release(); } catch (const std::exception& error) { std::fprintf(stderr, "window input cleanup: %s\n", error.what()); }
        if (keyboard) zwp_virtual_keyboard_v1_destroy(keyboard);
        if (pointer) zwlr_virtual_pointer_v1_destroy(pointer);
        if (physical) wl_keyboard_release(physical);
        if (keyboard_manager) zwp_virtual_keyboard_manager_v1_destroy(keyboard_manager);
        if (pointer_manager) zwlr_virtual_pointer_manager_v1_destroy(pointer_manager);
        if (seat) wl_seat_release(seat);
        if (registry) wl_registry_destroy(registry);
        if (display) { wl_display_flush(display); wl_display_disconnect(display); }
        if (state) xkb_state_unref(state);
        if (map) xkb_keymap_unref(map);
        if (context) xkb_context_unref(context);
    }
    static uint32_t time() {
        return static_cast<uint32_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    }
    static void global(void* data, wl_registry* registry, uint32_t name, const char* interface, uint32_t version) {
        auto& app = *static_cast<App*>(data);
        if (std::strcmp(interface, wl_seat_interface.name) == 0 && !app.seat)
            app.seat = static_cast<wl_seat*>(wl_registry_bind(registry, name, &wl_seat_interface, std::min(version, 5u)));
        else if (std::strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0)
            app.pointer_manager = static_cast<zwlr_virtual_pointer_manager_v1*>(wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1));
        else if (std::strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0)
            app.keyboard_manager = static_cast<zwp_virtual_keyboard_manager_v1*>(wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1));
    }
    static void removed(void*, wl_registry*, uint32_t) {}
    static void keymap(void* data, wl_keyboard*, uint32_t format, int32_t fd, uint32_t size) {
        auto& app = *static_cast<App*>(data);
        if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 || !size || size > 16 * 1024 * 1024) { close(fd); return; }
        void* bytes = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (bytes == MAP_FAILED) { close(fd); return; }
        if (app.keymap_text.size() == size && std::memcmp(app.keymap_text.data(), bytes, size) == 0) {
            munmap(bytes, size); close(fd); return;
        }
        xkb_keymap* next = nullptr;
        if (static_cast<const char*>(bytes)[size - 1] == '\0')
            next = xkb_keymap_new_from_string(app.context, static_cast<const char*>(bytes), XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
        if (next) {
            app.keymap_text.assign(static_cast<const char*>(bytes), size);
            zwp_virtual_keyboard_v1_keymap(app.keyboard, format, fd, size);
            if (app.state) xkb_state_unref(app.state);
            if (app.map) xkb_keymap_unref(app.map);
            app.map = next; app.state = xkb_state_new(next);
            for (auto code : app.held_keys) xkb_state_update_key(app.state, code + 8, XKB_KEY_DOWN);
        }
        munmap(bytes, size); close(fd);
    }
    static void enter(void*, wl_keyboard*, uint32_t, wl_surface*, wl_array*) {}
    static void leave(void*, wl_keyboard*, uint32_t, wl_surface*) {}
    static void key(void*, wl_keyboard*, uint32_t, uint32_t, uint32_t, uint32_t) {}
    static void modifiers(void*, wl_keyboard*, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t) {}
    static void repeat(void*, wl_keyboard*, int32_t, int32_t) {}
    void start() {
        display = wl_display_connect(nullptr); if (!display) throw std::runtime_error("connect Wayland display");
        registry = wl_display_get_registry(display);
        static const wl_registry_listener listener{global, removed}; wl_registry_add_listener(registry, &listener, this);
        if (wl_display_roundtrip(display) < 0 || !seat || !pointer_manager || !keyboard_manager)
            throw std::runtime_error("Wayland virtual pointer/keyboard unavailable");
        pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pointer_manager, seat);
        keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboard_manager, seat);
        physical = wl_seat_get_keyboard(seat);
        static const wl_keyboard_listener keyboard_listener{keymap, enter, leave, key, modifiers, repeat};
        wl_keyboard_add_listener(physical, &keyboard_listener, this);
        if (wl_display_roundtrip(display) < 0 || !state) throw std::runtime_error("read native keyboard layout");
    }
    std::string guard() const {
        // The client inventory serializes stable IDs as hexadecimal strings;
        // Lua window objects expose the same ID as an integer.
        return "local w=hl.get_window('address:" + address + "');assert(w and w.mapped and w.pid==" + std::to_string(pid) +
            " and w.stable_id==0x" + stable_id + ",'window target changed');";
    }
    void action(const std::string& body) {
        const auto result = ipc("/eval " + guard() + body);
        if (result.find("error") != std::string::npos || result.find("Error") != std::string::npos || result.find("window target changed") != std::string::npos)
            throw std::runtime_error("native window operation: " + result);
    }
    std::string move_pointer() const {
        return "hl.plugin.viewflow.with_forwarded_motion(function() hl.dispatch(hl.dsp.cursor.move({x=" + std::to_string(pointer_x / 1000.0) + ",y=" + std::to_string(pointer_y / 1000.0) + "})) end);";
    }
    void focus(bool move) {
        action("hl.plugin.viewflow.with_forwarded_motion(function() hl.dispatch(hl.dsp.focus({window=w}));" +
            (move && has_pointer ? move_pointer() : "") + " end);");
    }
    std::string button_command(uint32_t code, bool down) const {
        return "hl.plugin.viewflow.forwarded_button(" + std::to_string(code) + "," +
            std::to_string(down ? 1 : 0) + "," + std::to_string(time()) + ");";
    }
    void flush() {
        if (wl_display_roundtrip(display) < 0) throw std::runtime_error("Wayland input connection failed");
    }
    void send_modifiers() {
        zwp_virtual_keyboard_v1_modifiers(keyboard,
            xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED), xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
            xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED), xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE));
    }
    void release() {
        if (!display || !state) return;
        for (auto code : held_keys) {
            zwp_virtual_keyboard_v1_key(keyboard, time(), code, WL_KEYBOARD_KEY_STATE_RELEASED);
            xkb_state_update_key(state, code + 8, XKB_KEY_UP);
        }
        held_keys.clear(); send_modifiers();
        for (auto code : held_buttons) ipc("/eval " + button_command(code, false));
        held_buttons.clear(); zwlr_virtual_pointer_v1_frame(pointer); flush();
    }
    void input(const vf::Input& event) {
        if (event.sequence <= sequence) throw std::runtime_error("window input sequence regression");
        sequence = event.sequence;
        if (event.kind == vf::InputKind::release) { release(); return; }
        if (event.id != 1) throw std::runtime_error("unknown source window");
        switch (event.kind) {
        case vf::InputKind::pointer:
            pointer_x = event.a; pointer_y = event.b; has_pointer = true; action(move_pointer()); break;
        case vf::InputKind::button: {
            if (event.a < 272 || event.a > 276 || (event.b != 0 && event.b != 1)) return;
            const auto code = static_cast<uint32_t>(event.a);
            std::fprintf(stderr, "window-button received sequence=%llu down=%d capture-phase=%s\n",
                static_cast<unsigned long long>(event.sequence), event.b,
                ipc("/repl local s=hl.plugin.viewflow.capture_status();return s:match('\"phase\":(%d+)')").c_str());
            if ((event.b != 0) == held_buttons.contains(code)) return;
            // Position, focus and button dispatch must share one compositor
            // turn; physical capture can move the cursor between IPC and a
            // separate Wayland request. Nested refocus stays in the same scope.
            action("hl.plugin.viewflow.with_forwarded_motion(function() " +
                std::string(event.b ? "hl.dispatch(hl.dsp.focus({window=w}));" : "") +
                (has_pointer ? move_pointer() : "") + button_command(code, event.b != 0) + " end);");
            if (event.b) held_buttons.insert(code); else held_buttons.erase(code);
            flush(); break;
        }
        case vf::InputKind::key: {
            if (event.a <= 0 || event.a > 255 || event.b < 0 || event.b > 2) return;
            const auto code = static_cast<uint32_t>(event.a); const bool down = event.b != 0;
            if ((event.b == 1 && held_keys.contains(code)) || (event.b != 1 && !held_keys.contains(code))) return;
            if (down) focus(false);
            zwp_virtual_keyboard_v1_key(keyboard, time(), code, down ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
            if (event.b != 2) xkb_state_update_key(state, code + 8, down ? XKB_KEY_DOWN : XKB_KEY_UP);
            send_modifiers();
            if (down) held_keys.insert(code); else held_keys.erase(code);
            flush(); break;
        }
        case vf::InputKind::wheel: {
            std::fprintf(stderr,"window-scroll helper seq=%llu axis=%d amount=%d precise=%d stop=%d\n",
                static_cast<unsigned long long>(event.sequence),event.a,event.b,event.c,event.d);
            if (event.a != 0 && event.a != 1) return;
            // Position and scroll must share one compositor dispatch. The
            // forwarded-motion scope restores the physical cursor on return.
            const auto axis_call = [&](int amount) {
                return "hl.plugin.viewflow.forwarded_axis("+std::to_string(event.a)+","+
                    std::to_string(amount)+","+std::to_string(event.c==1?1:0)+","+std::to_string(time())+");";
            };
            action("hl.plugin.viewflow.with_forwarded_motion(function() hl.dispatch(hl.dsp.focus({window=w}));"+
                (has_pointer?move_pointer():"")+axis_call(event.b)+
                ((event.c==1 && event.d && event.b)?axis_call(0):"")+" end);");
            std::fprintf(stderr,"window-scroll synchronous seq=%llu\n",static_cast<unsigned long long>(event.sequence));
            break;
        }
        case vf::InputKind::focus: focus(false); break;
        case vf::InputKind::fullscreen:
            if(event.a!=0 && event.a!=1)throw std::runtime_error("invalid fullscreen state");
            action("hl.dispatch(hl.dsp.window.fullscreen({window=w,mode='fullscreen',action='"+std::string(event.a?"set":"unset")+"'}));"); break;
        case vf::InputKind::close: action("hl.dispatch(hl.dsp.window.close({window=w}));"); break;
        case vf::InputKind::geometry:
            if (event.c <= 0 || event.d <= 0) return;
            action("hl.dispatch(hl.dsp.window.resize({window=w,x=" + std::to_string(event.c / 1000.0) + ",y=" + std::to_string(event.d / 1000.0) +
                "}));hl.dispatch(hl.dsp.window.move({window=w,x=" + std::to_string(event.a / 1000.0) + ",y=" + std::to_string(event.b / 1000.0) + "}));"); break;
        default: throw std::runtime_error("unsupported native window input kind");
        }
    }
};
}
int main(int argc, char* argv[]) {
    std::signal(SIGPIPE, SIG_IGN);
    constexpr auto usage = "Usage: viewflow-linux-window-input WINDOW_HEX PID STABLE_ID\nPrivate helper for vf-hyprland-windows; no input is posted by --help.\n";
    if (argc == 2 && std::strcmp(argv[1], "--help") == 0) { std::puts(usage); return 0; }
    try {
        if (argc != 4) throw std::runtime_error(usage);
        App app; app.address = argv[1]; app.stable_id = argv[3];
        size_t used = 0; const auto pid = std::stoul(argv[2], &used);
        if (used != std::strlen(argv[2]) || pid == 0 || pid > INT32_MAX || !app.address.starts_with("0x") ||
            app.address.size() > 18 || app.address.size() < 3 || app.address.substr(2).find_first_not_of("0123456789abcdefABCDEF") != std::string::npos ||
            app.stable_id.empty() || app.stable_id.size() > 16 || app.stable_id.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos)
            throw std::runtime_error("invalid pinned window identity");
        app.pid = static_cast<unsigned>(pid); app.start();
        std::vector<uint8_t> bytes;
        while (vf::read_record(STDIN_FILENO, bytes)) {
            auto event = vf::unpack_input(bytes);
            try { app.input(event); event.d = 0; }
            catch (const std::exception& error) {
                std::fprintf(stderr, "window input recovering: %s\n", error.what());
                try { app.release(); } catch (...) {}
                event.d = 1;
            }
            vf::write_record(STDOUT_FILENO, vf::pack_input(event));
        }
        return 0;
    } catch (const std::exception& error) { std::fprintf(stderr, "window input: %s\n", error.what()); return 1; }
}
