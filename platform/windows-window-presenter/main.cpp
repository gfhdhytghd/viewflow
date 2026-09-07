#include <windows.h>
#include <windowsx.h>
#include <DispatcherQueue.h>
#include <d2d1_3.h>
#include <mfapi.h>
#include <windows.ui.composition.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.UI.Composition.h>
#include <winrt/Windows.UI.Composition.Desktop.h>
#include "../windows-video-compositor/video_compositor.h"
#include "../windows-composition-preview/frameless_window.h"
#include "../reverse-common/pipe_io.hpp"
#include <io.h>
#include <fcntl.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <thread>

namespace vf = viewflow::reverse;
namespace vw = viewflow::windows;
using namespace winrt;
using namespace winrt::Windows::UI::Composition;
using namespace winrt::Windows::UI::Composition::Desktop;
namespace {
struct Output {
    std::atomic<bool> stopped{false};
    std::mutex mutex; std::condition_variable changed;
    std::deque<std::vector<uint8_t>> records;
    std::thread worker;
    Output() : worker([this] {
        try {
            while (!stopped) {
                std::vector<uint8_t> record;
                { std::unique_lock lock(mutex); changed.wait(lock, [&] { return stopped || !records.empty(); });
                  if (stopped) break; record = std::move(records.front()); records.pop_front(); }
                vf::write_record(_fileno(stdout), record);
            }
        } catch (...) { stopped = true; }
    }) {}
    ~Output() { stopped = true; changed.notify_all(); CancelSynchronousIo(worker.native_handle()); worker.join(); }
    bool send(vf::Input event) {
        std::lock_guard lock(mutex);
        if (stopped || records.size() >= 4096) return false;
        records.push_back(vf::pack_input(event)); changed.notify_one(); return true;
    }
};
struct Reader {
    std::atomic<bool> stopped{false}, ended{false};
    std::mutex mutex; std::condition_variable changed;
    std::deque<vf::Frame> frames;
    std::thread worker;
    Reader() : worker([this] {
        try {
            std::vector<uint8_t> bytes;
            while (!stopped && vf::read_record(_fileno(stdin), bytes)) {
                auto frame = vf::unpack_frame(bytes);
                std::unique_lock lock(mutex);
                changed.wait(lock, [&] { return stopped || frames.size() < 2; });
                if (stopped) break;
                frames.push_back(std::move(frame));
            }
        } catch (const std::exception& error) { std::fprintf(stderr, "window media pipe: %s\n", error.what()); }
        ended = true;
    }) {}
    ~Reader() { stopped = true; changed.notify_all(); CancelSynchronousIo(worker.native_handle()); worker.join(); }
    std::optional<vf::Frame> take() {
        std::lock_guard lock(mutex); if (frames.empty()) return {};
        auto result = std::move(frames.front()); frames.pop_front(); changed.notify_one(); return result;
    }
};
struct App;
struct Proxy {
    App* app{}; vf::Tile tile;
    HWND window{};
    DesktopWindowTarget target{nullptr};
    SpriteVisual visual{nullptr};
    CompositionDrawingSurface surface{nullptr};
    CompositionSurfaceBrush brush{nullptr};
    unsigned width{}, height{}, buttons{};
    bool applying{}, moving{};
    uint64_t pending_geometry{};
    ~Proxy() { if (window) { SetWindowLongPtrW(window, GWLP_USERDATA, 0); DestroyWindow(window); } }
};
struct App {
    Output output;
    std::unique_ptr<vw::GpuVideoCompositor> decoder;
    Compositor compositor{nullptr};
    com_ptr<ID2D1Device> d2d;
    CompositionGraphicsDevice graphics{nullptr};
    std::map<uint64_t, std::unique_ptr<Proxy>> windows;
    std::map<uint64_t, vf::Frame> pending;
    uint64_t sequence{}, decode_sequence{};
    unsigned decoded_count{}, validation_errors{};
    int origin_x{}, origin_y{};
    double scale{1};
    bool validate{}, recovery_release{};
    uint64_t send(uint64_t id, vf::InputKind kind, int a = 0, int b = 0, int c = 0, int d = 0) {
        if (recovery_release) {
            if (!output.send({0, ++sequence, vf::InputKind::release, 0, 0, 0, 0})) return 0;
            recovery_release = false;
        }
        const auto next = ++sequence;
        if (!output.send({id, next, kind, a, b, c, d})) { recovery_release = true; return 0; }
        return next;
    }
    void pointer(Proxy& proxy, int x, int y) {
        RECT client{}; GetClientRect(proxy.window, &client);
        if (!client.right || !client.bottom) return;
        send(proxy.tile.id, vf::InputKind::pointer,
            static_cast<int>(std::lround(double(x) * proxy.tile.width / client.right)),
            static_cast<int>(std::lround(double(y) * proxy.tile.height / client.bottom)));
    }
    void geometry(Proxy& proxy) {
        if (proxy.applying) return;
        RECT rect{}; GetWindowRect(proxy.window, &rect);
        proxy.pending_geometry = send(proxy.tile.id, vf::InputKind::geometry,
            static_cast<int>(std::lround((rect.left - origin_x) * scale)), static_cast<int>(std::lround((rect.top - origin_y) * scale)),
            static_cast<int>(std::lround((rect.right - rect.left) * scale)), static_cast<int>(std::lround((rect.bottom - rect.top) * scale)));
    }
    static unsigned evdev(LPARAM value) {
        const auto scan = static_cast<unsigned>((value >> 16) & 255);
        if (!(value & (1 << 24))) return scan <= 88 ? scan : 0;
        switch (scan) { case 0x1c:return 96; case 0x1d:return 97; case 0x35:return 98; case 0x38:return 100;
            case 0x47:return 102; case 0x48:return 103; case 0x49:return 104; case 0x4b:return 105;
            case 0x4d:return 106; case 0x4f:return 107; case 0x50:return 108; case 0x51:return 109;
            case 0x52:return 110; case 0x53:return 111; case 0x5b:return 125; case 0x5c:return 126; case 0x5d:return 127; default:return 0; }
    }
    static LRESULT CALLBACK procedure(HWND hwnd, UINT message, WPARAM w, LPARAM l) {
        auto* proxy = reinterpret_cast<Proxy*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (message == WM_NCCREATE) {
            proxy = static_cast<Proxy*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);
            proxy->window = hwnd; SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(proxy));
        }
        if (!proxy) return DefWindowProcW(hwnd, message, w, l);
        auto& app = *proxy->app;
        if (const auto result = viewflow::windows_preview::FramelessMessage(hwnd, message, w, l)) return *result;
        switch (message) {
        case WM_NCHITTEST: {
            RECT rect{}; GetWindowRect(hwnd, &rect);
            return viewflow::windows_preview::FramelessHit(rect, GET_X_LPARAM(l), GET_Y_LPARAM(l), IsZoomed(hwnd) != FALSE);
        }
        case WM_MOUSEMOVE: app.pointer(*proxy, GET_X_LPARAM(l), GET_Y_LPARAM(l)); return 0;
        case WM_LBUTTONDOWN: case WM_LBUTTONUP: case WM_RBUTTONDOWN: case WM_RBUTTONUP:
        case WM_MBUTTONDOWN: case WM_MBUTTONUP: case WM_XBUTTONDOWN: case WM_XBUTTONUP: {
            const bool down = message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN || message == WM_MBUTTONDOWN || message == WM_XBUTTONDOWN;
            if (message == WM_LBUTTONDOWN && (GetKeyState(VK_MENU) & 0x8000)) {
                app.send(proxy->tile.id, vf::InputKind::release); ReleaseCapture();
                SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0); return 0;
            }
            const unsigned button = message == WM_LBUTTONDOWN || message == WM_LBUTTONUP ? 0
                : message == WM_RBUTTONDOWN || message == WM_RBUTTONUP ? 1
                : message == WM_MBUTTONDOWN || message == WM_MBUTTONUP ? 2 : GET_XBUTTON_WPARAM(w) == XBUTTON1 ? 3 : 4;
            if (down) { SetFocus(hwnd); SetCapture(hwnd); proxy->buttons |= 1u << button; }
            app.pointer(*proxy, GET_X_LPARAM(l), GET_Y_LPARAM(l));
            app.send(proxy->tile.id, vf::InputKind::button, 272 + static_cast<int>(button), down);
            if (!down) { proxy->buttons &= ~(1u << button); if (!proxy->buttons) ReleaseCapture(); }
            return 0;
        }
        case WM_MOUSEWHEEL: case WM_MOUSEHWHEEL: {
            POINT point{GET_X_LPARAM(l), GET_Y_LPARAM(l)}; ScreenToClient(hwnd, &point); app.pointer(*proxy, point.x, point.y);
            app.send(proxy->tile.id, vf::InputKind::wheel, message == WM_MOUSEHWHEEL, GET_WHEEL_DELTA_WPARAM(w)); return 0;
        }
        case WM_KEYDOWN: case WM_SYSKEYDOWN: case WM_KEYUP: case WM_SYSKEYUP: {
            const auto code = evdev(l); if (!code) return 0;
            const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
            app.send(proxy->tile.id, vf::InputKind::key, static_cast<int>(code), down ? ((l & (1LL << 30)) ? 2 : 1) : 0); return 0;
        }
        case WM_SETFOCUS: app.send(proxy->tile.id, vf::InputKind::focus); return 0;
        case WM_KILLFOCUS:
            proxy->buttons = 0; app.send(proxy->tile.id, vf::InputKind::release); return 0;
        case WM_CAPTURECHANGED:
            if (proxy->buttons) { proxy->buttons = 0; app.send(proxy->tile.id, vf::InputKind::release); } return 0;
        case WM_ENTERSIZEMOVE: proxy->moving = true; app.send(proxy->tile.id, vf::InputKind::release); return 0;
        case WM_EXITSIZEMOVE: proxy->moving = false; app.geometry(*proxy); return 0;
        case WM_SIZE:
            if (proxy->visual) proxy->visual.Size({float(LOWORD(l)), float(HIWORD(l))}); return 0;
        case WM_CLOSE: app.send(proxy->tile.id, vf::InputKind::close); return 0;
        case WM_ERASEBKGND: return 1;
        }
        return DefWindowProcW(hwnd, message, w, l);
    }
    void prepare() {
        decoder = std::make_unique<vw::GpuVideoCompositor>();
        check_hresult(vw::GpuVideoCompositor::Create(decoder.get(), 0, 2)); // Shared wire H264=1; compositor H264=2.
        pending.clear();
        if (validate) return;
        if (!compositor) compositor = Compositor();
        com_ptr<IDXGIDevice> dxgi; check_hresult(decoder->device()->QueryInterface(dxgi.put()));
        d2d = nullptr; check_hresult(D2D1CreateDevice(dxgi.get(), nullptr, d2d.put()));
        graphics = nullptr;
        auto interop = compositor.as<ABI::Windows::UI::Composition::ICompositorInterop>();
        check_hresult(interop->CreateGraphicsDevice(d2d.get(), reinterpret_cast<ABI::Windows::UI::Composition::ICompositionGraphicsDevice**>(put_abi(graphics))));
        for (auto& [_, proxy] : windows) { proxy->surface = nullptr; proxy->width = proxy->height = 0; }
    }
    void present(const vf::Frame& frame, const vw::CompositedFrame& decoded) {
        ++decoded_count;
        if (validate) { std::fprintf(stderr, "windows-window-validated frame=%u width=%u height=%u tiles=%zu\n", decoded_count, frame.width, frame.height, frame.tiles.size()); return; }
        std::set<uint64_t> live;
        for (const auto& tile : frame.tiles) {
            live.insert(tile.id);
            auto& entry = windows[tile.id];
            if (!entry) {
                entry = std::make_unique<Proxy>(); entry->app = this; entry->tile = tile;
                auto* proxy = entry.get();
                proxy->window = CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP, L"ViewflowPortableWindow", L"Shared window",
                    WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU,
                    0, 0, 1, 1, nullptr, nullptr, GetModuleHandleW(nullptr), proxy);
                if (!proxy->window) throw_last_error();
                auto desktop = compositor.as<ABI::Windows::UI::Composition::Desktop::ICompositorDesktopInterop>();
                check_hresult(desktop->CreateDesktopWindowTarget(proxy->window, true,
                    reinterpret_cast<ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(put_abi(proxy->target))));
                proxy->visual = compositor.CreateSpriteVisual(); proxy->target.Root(proxy->visual);
            }
            auto& proxy = *entry; proxy.tile = tile;
            if (!proxy.moving && (!proxy.pending_geometry || tile.geometry_ack >= proxy.pending_geometry)) {
                proxy.pending_geometry = 0; proxy.applying = true;
                SetWindowPos(proxy.window, nullptr, origin_x + static_cast<int>(std::lround(tile.x / scale)), origin_y + static_cast<int>(std::lround(tile.y / scale)),
                    static_cast<int>(std::lround(tile.width / scale)), static_cast<int>(std::lround(tile.height / scale)), SWP_NOACTIVATE | SWP_NOZORDER);
                proxy.applying = false;
            }
            const auto title = to_hstring(tile.title); SetWindowTextW(proxy.window, title.c_str());
            if (!proxy.surface || proxy.width != tile.width || proxy.height != tile.height) {
                proxy.surface = graphics.CreateDrawingSurface({float(tile.width), float(tile.height)},
                    winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,
                    winrt::Windows::Graphics::DirectX::DirectXAlphaMode::Premultiplied);
                proxy.brush = compositor.CreateSurfaceBrush(proxy.surface); proxy.brush.Stretch(CompositionStretch::Fill);
                proxy.visual.Brush(proxy.brush); proxy.width = tile.width; proxy.height = tile.height;
            }
            vw::CompositedFrame region;
            check_hresult(vw::MakeCompositedRegion(decoded, {tile.atlas_x, tile.atlas_y, tile.width, tile.height}, &region));
            auto drawing = proxy.surface.as<ABI::Windows::UI::Composition::ICompositionDrawingSurfaceInterop>();
            com_ptr<ID3D11Texture2D> destination; POINT offset{};
            check_hresult(drawing->BeginDraw(nullptr, __uuidof(ID3D11Texture2D), destination.put_void(), &offset));
            const auto copy = offset.x < 0 || offset.y < 0 ? E_INVALIDARG
                : vw::CopyCompositedRegion(decoder->context(), region, destination.get(), static_cast<unsigned>(offset.x), static_cast<unsigned>(offset.y));
            const auto ended = drawing->EndDraw(); check_hresult(copy); check_hresult(ended);
            RECT client{}; GetClientRect(proxy.window, &client); proxy.visual.Size({float(client.right), float(client.bottom)});
            ShowWindow(proxy.window, SW_SHOWNOACTIVATE);
        }
        decoder->context()->Flush();
        for (auto it = windows.begin(); it != windows.end();) {
            if (!live.contains(it->first)) { send(it->first, vf::InputKind::release); it = windows.erase(it); }
            else ++it;
        }
    }
    void frame(vf::Frame frame) {
        if (frame.codec != 1) throw std::runtime_error("Windows window presenter requires H264; configure macOS --codec h264");
        if (!decoder) { if (!frame.keyframe) return; prepare(); }
        const auto identity = ++decode_sequence;
        auto alpha = vf::decode_alpha(frame.alpha, static_cast<size_t>(frame.width) * frame.height);
        if (pending.size() >= 32) throw std::runtime_error("decoder produced no output; resetting local codec");
        const auto width = frame.width, height = frame.height;
        pending.emplace(identity, std::move(frame));
        std::vector<vw::CompositedFrame> completed;
        check_hresult(decoder->Submit(identity, pending.at(identity).color, {identity, width, height, alpha}, &completed));
        for (const auto& decoded : completed) {
            auto it = pending.find(decoded.frame_identity);
            if (it == pending.end() || decoded.width != it->second.width || decoded.height != it->second.height)
                throw std::runtime_error("decoded window/frame geometry mismatch");
            present(it->second, decoded); pending.erase(it);
        }
    }
    void finish() {
        if (!decoder) return;
        std::vector<vw::CompositedFrame> completed;
        check_hresult(decoder->Finish(&completed));
        for (const auto& decoded : completed) {
            auto it = pending.find(decoded.frame_identity);
            if (it == pending.end() || decoded.width != it->second.width || decoded.height != it->second.height)
                throw std::runtime_error("drained window/frame geometry mismatch");
            present(it->second, decoded); pending.erase(it);
        }
        if (validate && !pending.empty()) throw std::runtime_error("validation left undecoded window frames");
    }
};
}
int main(int argc, char* argv[]) {
    constexpr auto usage = "Usage: viewflow-windows-windows [--scale 1] [--origin-x PIXELS] [--origin-y PIXELS] [--validate]\nNative H264 window presenter for vf-window-peer. --validate decodes without creating windows or posting input.\n";
    if (argc == 2 && std::strcmp(argv[1], "--help") == 0) { std::puts(usage); return 0; }
    _setmode(_fileno(stdin), _O_BINARY); _setmode(_fileno(stdout), _O_BINARY);
    try {
        init_apartment(apartment_type::single_threaded);
        check_hresult(MFStartup(MF_VERSION));
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        DispatcherQueueOptions options{sizeof(options), DQTYPE_THREAD_CURRENT, DQTAT_COM_STA};
        com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;
        check_hresult(CreateDispatcherQueueController(options, queue.put()));
        App app;
        for (int i = 1; i < argc; ++i) {
            const std::string name = argv[i]; if (name == "--validate") { app.validate = true; continue; }
            if (++i == argc) throw std::runtime_error("missing argument value");
            size_t used = 0; const int value = std::stoi(argv[i], &used);
            if (used != std::strlen(argv[i])) throw std::runtime_error("invalid integer argument");
            if (name == "--scale" && value >= 1 && value <= 4) app.scale = value;
            else if (name == "--origin-x") app.origin_x = value;
            else if (name == "--origin-y") app.origin_y = value;
            else throw std::runtime_error("unknown argument");
        }
        WNDCLASSW cls{}; cls.lpfnWndProc = App::procedure; cls.hInstance = GetModuleHandleW(nullptr);
        cls.lpszClassName = L"ViewflowPortableWindow"; cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        if (!RegisterClassW(&cls)) throw_last_error();
        Reader reader;
        bool running = true;
        while (running && !app.output.stopped) {
            MSG message{};
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
                if (message.message == WM_QUIT) { running = false; break; }
                TranslateMessage(&message); DispatchMessageW(&message);
            }
            if (auto frame = reader.take()) {
                try { app.frame(std::move(*frame)); }
                catch (const hresult_error& error) { std::fprintf(stderr, "window GPU recovering: %s\n", to_string(error.message()).c_str()); ++app.validation_errors; app.decoder.reset(); app.pending.clear(); }
                catch (const std::exception& error) { std::fprintf(stderr, "window presentation recovering: %s\n", error.what()); ++app.validation_errors; app.decoder.reset(); app.pending.clear(); }
            } else if (reader.ended) break;
            else MsgWaitForMultipleObjects(0, nullptr, FALSE, 5, QS_ALLINPUT);
        }
        if (reader.ended) app.finish();
        if (app.validate && (app.decoded_count == 0 || app.validation_errors)) throw std::runtime_error("window decoder validation failed");
        return 0;
    } catch (const hresult_error& error) { std::fprintf(stderr, "windows presenter: %s\n", to_string(error.message()).c_str()); return 1; }
    catch (const std::exception& error) { std::fprintf(stderr, "windows presenter: %s\n", error.what()); return 1; }
}
