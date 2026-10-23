#include <windows.h>
#include "../reverse-common/activity_presentation.hpp"
#include "../reverse-common/activity_frame_queue.hpp"
#include "../reverse-common/activity_feedback.hpp"
#include "../reverse-common/activity_input.hpp"
#include "../reverse-common/activity_hint.hpp"
#include <windowsx.h>
#include <dwmapi.h>
#include <imm.h>
#include "window_geometry.hpp"
#include <shobjidl.h>
#include <shellapi.h>
#include <propkey.h>
#include <propvarutil.h>
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
#include "../reverse-common/window_residency.hpp"
#include "../reverse-common/geometry_sync.hpp"
#include <io.h>
#include <fcntl.h>
#include <atomic>
#include <array>
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
    struct Record {vf::Input input;std::vector<std::uint8_t> feedback;};
    std::deque<Record> records;
    std::thread worker;
    Output() : worker([this] {
        try {
            while (!stopped) {
                Record record;
                { std::unique_lock lock(mutex); changed.wait(lock, [&] { return stopped || !records.empty(); });
                  if (stopped) break; record = std::move(records.front()); records.pop_front(); }
                vf::write_record(_fileno(stdout), record.feedback.empty()?vf::pack_input(record.input):record.feedback);
            }
        } catch (...) { stopped = true; }
    }) {}
    ~Output() { stopped = true; changed.notify_all(); CancelSynchronousIo(worker.native_handle()); worker.join(); }
    bool send(vf::Input event) {
        std::lock_guard lock(mutex);
        if (stopped) return false;
        // Coalesce only adjacent geometry for the same window. Button releases
        // and other ordered input remain barriers, and the latest sequence wins.
        if (event.kind == vf::InputKind::geometry && !records.empty() &&
            records.back().feedback.empty() && records.back().input.kind == event.kind && records.back().input.id == event.id) {
            records.back().input = event; changed.notify_one(); return true;
        }
        if (records.size() >= 4096) return false;
        records.push_back({event,{}}); changed.notify_one(); return true;
    }
    void interaction(std::uint64_t window,bool active){
        if(!viewflow::activity::negotiated())return;
        std::lock_guard lock(mutex);if(stopped || records.size()>=4096)return;
        records.push_back({{},viewflow::activity::pack_hint({window,1,active})});changed.notify_one();
    }
    void feedback(viewflow::activity::Feedback hint) {
        if(!viewflow::activity::negotiated())return;
        std::lock_guard lock(mutex);if(stopped || records.size()>=4096)return;
        records.push_back({{},viewflow::activity::pack_feedback(hint)});changed.notify_one();
    }

};
struct Reader {
    std::atomic<bool> stopped{false}, ended{false};
    std::mutex mutex; std::condition_variable changed;
    std::deque<vf::Frame> frames;
    viewflow::activity::FrameQueue lanes[2];Output* output{};
    std::chrono::steady_clock::time_point last_background{};
    std::thread worker;
    explicit Reader(Output* sink) : output(sink),worker([this] {
        try {
            std::vector<uint8_t> bytes;
            while (!stopped && vf::read_record(_fileno(stdin), bytes)) {
                auto frame = vf::unpack_frame(bytes);
                std::unique_lock lock(mutex);
                if(frame.activity_epoch){
                    const auto lane=frame.activity_lane;const bool request=lanes[lane].push(std::move(frame),viewflow::activity::now_us());
                    if(request)output->feedback({lane,true,true,false,0,1});continue;
                }
                changed.wait(lock, [&] { return stopped || frames.size() < 2; });
                if (stopped) break;
                frames.push_back(std::move(frame));
            }
        } catch (const std::exception& error) { std::fprintf(stderr, "window media pipe: %s\n", error.what()); }
        ended = true;
    }) {}
    ~Reader() { stopped = true; changed.notify_all(); CancelSynchronousIo(worker.native_handle()); worker.join(); }
    std::optional<vf::Frame> take() {
        std::lock_guard lock(mutex);
        std::optional<vf::Frame> selected;
        if(std::chrono::steady_clock::now()-last_background>=std::chrono::milliseconds(200))selected=lanes[0].pop();
        if(!selected)selected=lanes[1].pop();if(!selected)selected=lanes[0].pop();
        if(selected){const auto lane=selected->activity_lane;if(!lane)last_background=std::chrono::steady_clock::now();
            output->feedback({lane,false,lanes[lane].saturated(),false,lanes[lane].age(viewflow::activity::now_us()),1});return selected;}
        if (frames.empty()) return {};
        auto result = std::move(frames.front()); frames.pop_front(); changed.notify_one(); return result;
    }
};
struct App;
struct Proxy {
    App* app{}; vf::Tile tile;unsigned media_lane=2;
    HWND window{}, shadow_window{};
    HICON app_icon{};std::string source_app_id;
    DesktopWindowTarget shadow_target{nullptr};
    ContainerVisual shadow_root{nullptr};
    RECT input_region{};
    DesktopWindowTarget target{nullptr};
    ContainerVisual root{nullptr};
    SpriteVisual visual{nullptr};
    std::vector<SpriteVisual> shadows;
    std::vector<DropShadow> shadow_effects;
    CompositionDrawingSurface surface{nullptr};
    CompositionSurfaceBrush brush{nullptr};
    unsigned width{}, height{}, buttons{};
    std::shared_ptr<const std::vector<uint8_t>> alpha; unsigned atlas_width{};
    bool applying{}, moving{}, shown{}, geometry_queued{};
    uint64_t pending_geometry{};
    vf::NativeMoveConfirmation titlebar;
    POINT grab{}, click{};
    bool takeover_pending{}, source_drag_consumed{}, source_hint_seen{};
    std::string displayed_title;
    vf::PixelRect reported_resident{};
    bool resident_reported{};unsigned reported_width{},reported_height{};
    ~Proxy() { if(app_icon)DestroyIcon(app_icon);if(shadow_window)DestroyWindow(shadow_window); if (window) { SetWindowLongPtrW(window, GWLP_USERDATA, 0); DestroyWindow(window); } }
};
struct App {
    Output output;
    struct DecodeLane {
        std::unique_ptr<vw::GpuVideoCompositor> decoder;
        com_ptr<ID2D1Device> d2d;
        CompositionGraphicsDevice graphics{nullptr};
        std::map<uint64_t, vf::Frame> pending;
        std::map<uint64_t, std::shared_ptr<const std::vector<uint8_t>>> pending_alpha;
        std::vector<uint8_t> encoded_alpha;
        std::shared_ptr<const std::vector<uint8_t>> cached_alpha;
        unsigned alpha_width{},alpha_height{};
    };
    DecodeLane lanes[2];unsigned active_lane{};
    viewflow::activity::Presentation activity_presentation;
    Compositor compositor{nullptr};
    std::map<uint64_t, std::unique_ptr<Proxy>> windows;
    void reset_lane() { lanes[active_lane]=DecodeLane{};output.feedback({active_lane,true,false,active_lane==1,0,1}); }
    uint64_t alpha_updates{}, statistics_frames{};
    double statistics_decode_ms{},statistics_present_ms{};
    std::chrono::steady_clock::time_point statistics_start=std::chrono::steady_clock::now();
    uint64_t sequence{}, decode_sequence{};
    unsigned decoded_count{}, validation_errors{};
    int origin_x{}, origin_y{};
    double scale{1};
    bool validate{}, recovery_release{};
    Reader* reader{};
    bool pumping{}, buttons_sampled{}, sampled_left{};
    static constexpr UINT takeover_message = WM_APP + 32;
    static constexpr UINT_PTR drag_timer = 0x5646;
    uint64_t send(uint64_t id, vf::InputKind kind, int a = 0, int b = 0, int c = 0, int d = 0) {
        if (recovery_release) {
            if (!output.send({0, ++sequence, vf::InputKind::release, 0, 0, 0, 0})) return 0;
            recovery_release = false;
        }
        const auto next = ++sequence;
        if (!output.send({id, next, kind, a, b, c, d})) { recovery_release = true; return 0; }
        return next;
    }
    viewflow::portable::Geometry geometry_layout(const Proxy& proxy) const {
        return viewflow::portable::geometry(proxy.tile,scale,IsZoomed(proxy.window)!=FALSE);
    }
    void apply_icon(Proxy& proxy,const vf::Tile& tile) {
        if(!(tile.flags&vf::application_icon_flag) || tile.icon_png.empty())return;
        auto icon=CreateIconFromResourceEx(const_cast<PBYTE>(tile.icon_png.data()),DWORD(tile.icon_png.size()),TRUE,0x00030000,0,0,LR_DEFAULTCOLOR);
        if(!icon){std::fprintf(stderr,"application-icon-decode failed window=%llu error=%lu\n",static_cast<unsigned long long>(tile.id),GetLastError());return;}
        uint64_t hash=0xcbf29ce484222325ULL;for(unsigned char c:tile.app_id)hash=(hash^c)*0x100000001b3ULL;
        const auto group=L"Viewflow.Remote."+std::to_wstring(hash);
        com_ptr<IPropertyStore> properties;
        if(SUCCEEDED(SHGetPropertyStoreForWindow(proxy.window,IID_PPV_ARGS(properties.put())))) {
            PROPVARIANT value{};
            if(SUCCEEDED(InitPropVariantFromString(group.c_str(),&value))){properties->SetValue(PKEY_AppUserModel_ID,value);properties->Commit();PropVariantClear(&value);}
        }
        SendMessageW(proxy.window,WM_SETICON,ICON_BIG,reinterpret_cast<LPARAM>(icon));
        SendMessageW(proxy.window,WM_SETICON,ICON_SMALL,reinterpret_cast<LPARAM>(icon));
        if(proxy.app_icon)DestroyIcon(proxy.app_icon);proxy.app_icon=icon;proxy.source_app_id=tile.app_id;
        std::fprintf(stderr,"application-icon-applied window=%llu app=%s bytes=%zu\n",static_cast<unsigned long long>(tile.id),tile.app_id.c_str(),tile.icon_png.size());
    }
    void sync_shadow(Proxy& proxy) {
        if(!proxy.shadow_window)return;
        RECT r{};GetWindowRect(proxy.window,&r);
        const auto pad=LONG(std::ceil(geometry_layout(proxy).padding));
        SetWindowPos(proxy.shadow_window,proxy.window,r.left-pad,r.top-pad,r.right-r.left+pad*2,r.bottom-r.top+pad*2,
            SWP_NOACTIVATE | (IsWindowVisible(proxy.window)&&!IsIconic(proxy.window)&&!IsZoomed(proxy.window)?SWP_SHOWWINDOW:SWP_HIDEWINDOW));
    }
    void resize_visual(Proxy& proxy) {
        if (!proxy.visual) return;
        RECT client{}; GetClientRect(proxy.window, &client);
        const auto layout=geometry_layout(proxy);
        const auto crop = vf::resident_rect(proxy.tile);
        const float sx=float(client.right/layout.width),sy=float(client.bottom/layout.height);
        proxy.visual.Size({float(crop.width*layout.pixel_x*sx),float(crop.height*layout.pixel_y*sy)});
        proxy.visual.Offset({float((layout.image_x+crop.x*layout.pixel_x)*sx),float((layout.image_y+crop.y*layout.pixel_y)*sy),0});
        proxy.visual.Opacity(crop.width > 0 && crop.height > 0 ? 1.f : 0.f);
        // The interactive HWND excludes exterior shadow pixels. HTTRANSPARENT
        // only traverses windows in the same thread, while streams use separate processes.
        RECT body{LONG(std::floor(layout.body_x*sx)),LONG(std::floor(layout.body_y*sy)),
            LONG(std::ceil((layout.body_x+layout.body_width)*sx)),LONG(std::ceil((layout.body_y+layout.body_height)*sy))};
        if(proxy.shadow_window && !EqualRect(&body,&proxy.input_region)) {
            auto region=CreateRectRgn(body.left,body.top,body.right,body.bottom);
            if(SetWindowRgn(proxy.window,region,TRUE))proxy.input_region=body;else DeleteObject(region);
        }
        for (auto& shadow:proxy.shadows) {
            shadow.Size(proxy.visual.Size());
            const auto offset=proxy.visual.Offset();shadow.Offset({offset.x+float(layout.padding),offset.y+float(layout.padding),0});shadow.Opacity(IsZoomed(proxy.window)?0.f:proxy.visual.Opacity());
        }
    }
    void visibility(Proxy& proxy) {
        if(!(proxy.tile.flags & vf::residency_capability))return;
        vf::PixelRect visible{};
        RECT client{}; GetClientRect(proxy.window, &client);
        POINT origin{}; ClientToScreen(proxy.window, &origin);
        const auto layout=geometry_layout(proxy);
        const double sx=client.right/layout.width,sy=client.bottom/layout.height;
        const double image_x=origin.x+layout.image_x*sx,image_y=origin.y+layout.image_y*sy;
        const double pixel_x=layout.pixel_x*sx,pixel_y=layout.pixel_y*sy;
        if (IsWindowVisible(proxy.window) && !IsIconic(proxy.window) && pixel_x>0 && pixel_y>0) {
            const double left=std::max(image_x,double(GetSystemMetrics(SM_XVIRTUALSCREEN)));
            const double top=std::max(image_y,double(GetSystemMetrics(SM_YVIRTUALSCREEN)));
            const double right=std::min(image_x+proxy.tile.width*pixel_x,double(GetSystemMetrics(SM_XVIRTUALSCREEN)+GetSystemMetrics(SM_CXVIRTUALSCREEN)));
            const double bottom=std::min(image_y+proxy.tile.height*pixel_y,double(GetSystemMetrics(SM_YVIRTUALSCREEN)+GetSystemMetrics(SM_CYVIRTUALSCREEN)));
            if (right>left && bottom>top) {
                const int x=std::max(0,int(std::floor((left-image_x)/pixel_x))-256);
                const int y=std::max(0,int(std::floor((top-image_y)/pixel_y))-256);
                const int r=std::min(int(proxy.tile.width),int(std::ceil((right-image_x)/pixel_x))+256);
                const int b=std::min(int(proxy.tile.height),int(std::ceil((bottom-image_y)/pixel_y))+256);
                visible={unsigned(x),unsigned(y),unsigned(r-x),unsigned(b-y)};
            }
        }
        visible=vf::align_resident(visible,proxy.tile.width,proxy.tile.height);
        if (!proxy.resident_reported || !(visible == proxy.reported_resident) || proxy.reported_width!=proxy.tile.width || proxy.reported_height!=proxy.tile.height) {
            if (send(proxy.tile.id, vf::InputKind::visibility, visible.x, visible.y, visible.width, visible.height)) {
                proxy.reported_resident=visible; proxy.resident_reported=true;proxy.reported_width=proxy.tile.width;proxy.reported_height=proxy.tile.height;
            }
        }
    }
    void pointer(Proxy& proxy, int x, int y) {
        RECT client{}; GetClientRect(proxy.window, &client);
        if (!client.right || !client.bottom) return;
        POINT point{x,y};ClientToScreen(proxy.window,&point);
        send(proxy.tile.id,vf::InputKind::pointer,
            int(std::lround((point.x-origin_x)*scale)),int(std::lround((point.y-origin_y)*scale)),1);
    }
    void geometry(Proxy& proxy) {
        if (proxy.applying) return;
        RECT rect{}; GetWindowRect(proxy.window, &rect);
        const auto layout=geometry_layout(proxy);
        const double sx=(rect.right-rect.left)/layout.width,sy=(rect.bottom-rect.top)/layout.height;
        const auto sent = send(proxy.tile.id, vf::InputKind::geometry,
            int(std::lround((rect.left+layout.body_x*sx-origin_x)*scale)),
            int(std::lround((rect.top+layout.body_y*sy-origin_y)*scale)),
            int(std::lround(layout.body_width*sx*scale)),int(std::lround(layout.body_height*sy*scale)));
        if (sent) proxy.pending_geometry = sent;
        proxy.geometry_queued = !sent;
    }

    void source_drag(Proxy& proxy) {
        if(!(proxy.tile.flags&1)) { proxy.source_drag_consumed=false;proxy.source_hint_seen=false;return; }
        if(!proxy.source_hint_seen) {
            proxy.source_hint_seen=true;
            std::fprintf(stderr,"windows-source-drag-hint window=%llu held=%u flags=%u\n",static_cast<unsigned long long>(proxy.tile.id),unsigned((GetAsyncKeyState(VK_LBUTTON)&0x8000)!=0),proxy.tile.flags);
        }
        if(proxy.source_drag_consumed || proxy.moving || proxy.takeover_pending || (proxy.tile.flags&2) || !(proxy.tile.flags&4))return;
        if(!(GetAsyncKeyState(VK_LBUTTON)&0x8000))return;
        const auto layout=geometry_layout(proxy);
        const double unit=(proxy.tile.flags&16)?double(proxy.tile.pixel_scale)/scale:1./scale;
        proxy.grab={LONG(std::lround(layout.body_x+proxy.tile.grab_x*unit)),LONG(std::lround(layout.body_y+proxy.tile.grab_y*unit))};
        proxy.buttons|=1u;proxy.source_drag_consumed=true;
        proxy.takeover_pending=PostMessageW(proxy.window,takeover_message,0,0)!=FALSE;
        std::fprintf(stderr,"windows-source-drag-handoff window=%llu grab=%ld,%ld queued=%u\n",
            static_cast<unsigned long long>(proxy.tile.id),proxy.grab.x,proxy.grab.y,unsigned(proxy.takeover_pending));
    }
    void finish_source_drag(Proxy& proxy) {
        if(!(proxy.tile.flags&1) || !(proxy.tile.flags&4) || proxy.source_drag_consumed || proxy.moving)return;
        const auto layout=geometry_layout(proxy);
        const double unit=(proxy.tile.flags&16)?double(proxy.tile.pixel_scale)/scale:1./scale;
        POINT point{};GetCursorPos(&point);
        proxy.applying=true;
        SetWindowPos(proxy.window,nullptr,LONG(std::lround(point.x-layout.body_x-proxy.tile.grab_x*unit)),
            LONG(std::lround(point.y-layout.body_y-proxy.tile.grab_y*unit)),0,0,SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE);
        proxy.applying=false;proxy.source_drag_consumed=true;geometry(proxy);
        std::fprintf(stderr,"windows-source-drag-drop window=%llu cursor=%ld,%ld\n",static_cast<unsigned long long>(proxy.tile.id),point.x,point.y);
    }
    void poll_source_drags() {
        const bool left=(GetAsyncKeyState(VK_LBUTTON)&0x8000)!=0;
        for(auto& [_,proxy]:windows) {
            if(buttons_sampled && sampled_left && !left)finish_source_drag(*proxy);
            else source_drag(*proxy);
        }
        buttons_sampled=true;sampled_left=left;
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
            const auto layout=app.geometry_layout(*proxy);
            const double sx=(rect.right-rect.left)/layout.width,sy=(rect.bottom-rect.top)/layout.height;
            RECT body{LONG(std::lround(rect.left+layout.body_x*sx)),LONG(std::lround(rect.top+layout.body_y*sy)),
                LONG(std::lround(rect.left+(layout.body_x+layout.body_width)*sx)),LONG(std::lround(rect.top+(layout.body_y+layout.body_height)*sy))};
            POINT point{GET_X_LPARAM(l),GET_Y_LPARAM(l)};
            if (!PtInRect(&body,point)) return HTTRANSPARENT; // Shadows never intercept a neighbouring window.
            if(proxy->alpha && sx>0 && sy>0) {
                const int x=int((point.x-rect.left-layout.image_x*sx)/(layout.pixel_x*sx));
                const int y=int((point.y-rect.top-layout.image_y*sy)/(layout.pixel_y*sy));
                const auto crop=vf::resident_rect(proxy->tile);
                if(x>=int(crop.x) && y>=int(crop.y) && x<int(crop.x+crop.width) && y<int(crop.y+crop.height)) {
                    const auto index=size_t(proxy->tile.atlas_y+y-crop.y)*proxy->atlas_width+proxy->tile.atlas_x+x-crop.x;
                    if(index<proxy->alpha->size() && (*proxy->alpha)[index]<=8)return HTTRANSPARENT;
                }
            }
            if (proxy->tile.flags&2) return HTCLIENT;
            return viewflow::windows_preview::FramelessHit(body,point.x,point.y,IsZoomed(hwnd)!=FALSE);
        }
        case WM_MOUSEACTIVATE:
            if(proxy->tile.flags&2)return MA_NOACTIVATE;
            SetForegroundWindow(hwnd);SetWindowPos(hwnd,HWND_TOP,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE);
            return MA_ACTIVATE;

        case takeover_message: {
            if (!proxy->takeover_pending) return 0;
            proxy->takeover_pending = false;
            if (!(proxy->buttons & 1) || !(GetAsyncKeyState(VK_LBUTTON) & 0x8000)) return 0;
            POINT cursor{}; GetCursorPos(&cursor);
            app.send(proxy->tile.id, vf::InputKind::button, 272, 0);
            proxy->buttons &= ~1u; ReleaseCapture();
            proxy->applying = true;
            SetWindowPos(hwnd, nullptr, cursor.x-proxy->grab.x, cursor.y-proxy->grab.y,
                         0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            proxy->applying = false;
            app.geometry(*proxy);
            SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(cursor.x, cursor.y));
            return 0;
        }
        case WM_TIMER:
            if (w == drag_timer) { app.pump(); return 0; } break;
        case WM_MOUSEMOVE:
            // Window creation can synthesize hover before the inherited down
            // reaches this input queue. Hover must not cancel a confirmed drag.
            app.pointer(*proxy, GET_X_LPARAM(l), GET_Y_LPARAM(l)); return 0;
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
            if (message == WM_LBUTTONDOWN && !(proxy->tile.flags & 2) && !proxy->pending_geometry && !proxy->geometry_queued) {
                RECT rect{}; GetWindowRect(hwnd, &rect); GetCursorPos(&proxy->click);
                proxy->grab = {proxy->click.x-rect.left, proxy->click.y-rect.top};
                proxy->titlebar.begin({proxy->tile.x, proxy->tile.y,
                    int((proxy->tile.flags & 16) ? proxy->tile.logical_width : proxy->tile.width),
                    int((proxy->tile.flags & 16) ? proxy->tile.logical_height : proxy->tile.height)}, proxy->tile.geometry_ack);
            }
            if (message == WM_LBUTTONUP) { app.finish_source_drag(*proxy);proxy->titlebar.cancel(); proxy->takeover_pending = false; }
            if (down) { if(!(proxy->tile.flags&2))SetFocus(hwnd); SetCapture(hwnd); proxy->buttons |= 1u << button; }
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
        case WM_ENTERSIZEMOVE:
            proxy->moving = true;app.output.interaction(proxy->tile.id,true); proxy->titlebar.cancel();
            app.send(proxy->tile.id, vf::InputKind::release); SetTimer(hwnd, drag_timer, 10, nullptr); return 0;
        case WM_EXITSIZEMOVE:
            app.geometry(*proxy); proxy->moving = false;app.output.interaction(proxy->tile.id,false); KillTimer(hwnd, drag_timer); return 0;
        case WM_WINDOWPOSCHANGED:
            app.sync_shadow(*proxy);
            if (proxy->moving) app.geometry(*proxy);
            break;
        case WM_SIZE:
            app.resize_visual(*proxy); return 0;
        case WM_CLOSE: app.send(proxy->tile.id, vf::InputKind::close); return 0;
        case WM_ERASEBKGND: return 1;
        }
        return DefWindowProcW(hwnd, message, w, l);
    }
    void prepare() {
        auto& lane=lanes[active_lane];auto& decoder=lane.decoder;
        auto& pending=lane.pending;auto& pending_alpha=lane.pending_alpha;
        auto& d2d=lane.d2d;auto& graphics=lane.graphics;
        decoder = std::make_unique<vw::GpuVideoCompositor>();
        check_hresult(vw::GpuVideoCompositor::Create(decoder.get(), 0, 2)); // Shared wire H264=1; compositor H264=2.
        pending.clear(); pending_alpha.clear();
        if (validate) return;
        if (!compositor) compositor = Compositor();
        com_ptr<IDXGIDevice> dxgi; check_hresult(decoder->device()->QueryInterface(dxgi.put()));
        d2d = nullptr; check_hresult(D2D1CreateDevice(dxgi.get(), nullptr, d2d.put()));
        graphics = nullptr;
        auto interop = compositor.as<ABI::Windows::UI::Composition::ICompositorInterop>();
        check_hresult(interop->CreateGraphicsDevice(d2d.get(), reinterpret_cast<ABI::Windows::UI::Composition::ICompositionGraphicsDevice**>(put_abi(graphics))));
        for (auto& [_, proxy] : windows) if(proxy->media_lane==active_lane){ proxy->surface = nullptr; proxy->width = proxy->height = 0; }
    }
    void present(const vf::Frame& frame, const vw::CompositedFrame& decoded) {
        auto& lane=lanes[active_lane];auto& decoder=lane.decoder;
        auto& pending_alpha=lane.pending_alpha;auto& graphics=lane.graphics;
        if(!activity_presentation.admit(frame))return;
        ++decoded_count;
        if (validate) { std::fprintf(stderr, "windows-window-validated frame=%u width=%u height=%u tiles=%zu\n", decoded_count, frame.width, frame.height, frame.tiles.size()); return; }
        auto live=activity_presentation.members(frame);
        for (const auto& tile : frame.tiles) {
            if(!activity_presentation.accepts(frame,tile))continue;
            auto& entry = windows[tile.id];
            if (!entry) {
                entry = std::make_unique<Proxy>(); entry->app = this; entry->tile = tile;
                auto* proxy = entry.get();
                proxy->window = CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP | ((tile.flags&2)?WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW:0), L"ViewflowPortableWindow", L"Shared window",
                    WS_POPUP | ((tile.flags&2)?0:WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU),
                    0, 0, 1, 1, nullptr, nullptr, GetModuleHandleW(nullptr), proxy);
                if (!proxy->window) throw_last_error();
                ImmAssociateContext(proxy->window,nullptr); // Composition belongs to the source Mac IME.
                const DWM_WINDOW_CORNER_PREFERENCE corner=DWMWCP_DONOTROUND;
                DwmSetWindowAttribute(proxy->window,DWMWA_WINDOW_CORNER_PREFERENCE,&corner,sizeof(corner));
                const DWMNCRENDERINGPOLICY nc=DWMNCRP_DISABLED;
                DwmSetWindowAttribute(proxy->window,DWMWA_NCRENDERING_POLICY,&nc,sizeof(nc));
                auto desktop = compositor.as<ABI::Windows::UI::Composition::Desktop::ICompositorDesktopInterop>();
                check_hresult(desktop->CreateDesktopWindowTarget(proxy->window, true,
                    reinterpret_cast<ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(put_abi(proxy->target))));
                proxy->root=compositor.CreateContainerVisual();proxy->target.Root(proxy->root);
                if((tile.flags&16) && !(tile.flags&2)) {
                    // A fully input-transparent separate HWND preserves cross-process clicks.
                    proxy->shadow_window=CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP|WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW,
                        L"ViewflowPortableShadow",L"Viewflow window shadow",WS_POPUP,0,0,1,1,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
                    if(!proxy->shadow_window)throw_last_error();
                    SetLayeredWindowAttributes(proxy->shadow_window,0,255,LWA_ALPHA);
                    check_hresult(desktop->CreateDesktopWindowTarget(proxy->shadow_window,true,
                        reinterpret_cast<ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(put_abi(proxy->shadow_target))));
                    proxy->shadow_root=compositor.CreateContainerVisual();proxy->shadow_target.Root(proxy->shadow_root);
                    // Three alpha-shaped lobes, matching the Mac proxy's broad and contact shadows.
                    const float unit=float(tile.pixel_scale/scale);
                    for (const auto& lobe:std::array<std::array<float,3>,3>{{{88,17.5f,.233f},{74,19,.107f},{2,0,.32f}}}) {
                        auto shadow=compositor.CreateSpriteVisual();auto effect=compositor.CreateDropShadow();
                        effect.BlurRadius(std::min(250.f,lobe[0]*unit));effect.Offset({0,lobe[1]*unit,0});effect.Opacity(lobe[2]);
                        effect.Color(winrt::Windows::UI::Color{255,0,0,0});shadow.Shadow(effect);
                        proxy->shadow_root.Children().InsertAtTop(shadow);proxy->shadows.push_back(shadow);proxy->shadow_effects.push_back(effect);
                    }
                }
                proxy->visual = compositor.CreateSpriteVisual();proxy->root.Children().InsertAtTop(proxy->visual);
            }
            auto& proxy = *entry;
            if(proxy.media_lane!=active_lane){proxy.media_lane=active_lane;proxy.surface=nullptr;proxy.width=proxy.height=0;} proxy.tile = tile;
            apply_icon(proxy,tile);
            if(tile.owner && windows.contains(tile.owner))SetWindowLongPtrW(proxy.window,GWLP_HWNDPARENT,reinterpret_cast<LONG_PTR>(windows.at(tile.owner)->window));
            proxy.alpha=pending_alpha.at(decoded.frame_identity);proxy.atlas_width=frame.width;
            POINT cursor{}; GetCursorPos(&cursor);
            if (!proxy.moving && (proxy.buttons & 1) &&
                (cursor.x != proxy.click.x || cursor.y != proxy.click.y) &&
                proxy.titlebar.observe({tile.x, tile.y, int((tile.flags & 16) ? tile.logical_width : tile.width), int((tile.flags & 16) ? tile.logical_height : tile.height)}, tile.geometry_ack)) {
                proxy.takeover_pending = PostMessageW(proxy.window, takeover_message, 0, 0) != FALSE;
            }
            if (!proxy.moving && !proxy.takeover_pending && !proxy.geometry_queued && (!proxy.pending_geometry || tile.geometry_ack >= proxy.pending_geometry)) {
                proxy.pending_geometry = 0; proxy.applying = true;
                const auto layout=geometry_layout(proxy);
                const int x=origin_x+int(std::lround(tile.x/scale-layout.body_x));
                const int y=origin_y+int(std::lround(tile.y/scale-layout.body_y));
                const int width=int(std::lround(layout.width)),height=int(std::lround(layout.height));
                RECT current{};GetWindowRect(proxy.window,&current);
                if(current.left!=x || current.top!=y || current.right-current.left!=width || current.bottom-current.top!=height)
                    SetWindowPos(proxy.window,nullptr,x,y,width,height,SWP_NOACTIVATE|SWP_NOZORDER);

                proxy.applying = false;
            }
            if(proxy.displayed_title!=tile.title) { const auto title=to_hstring(tile.title);SetWindowTextW(proxy.window,title.c_str());proxy.displayed_title=tile.title; }
            const auto crop = vf::resident_rect(tile);
            if (crop.width > 0 && crop.height > 0) {
                if (!proxy.surface || proxy.width != unsigned(crop.width) || proxy.height != unsigned(crop.height)) {
                    proxy.surface = graphics.CreateDrawingSurface({float(crop.width), float(crop.height)},
                        winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,
                        winrt::Windows::Graphics::DirectX::DirectXAlphaMode::Premultiplied);
                    proxy.brush = compositor.CreateSurfaceBrush(proxy.surface); proxy.brush.Stretch(CompositionStretch::Fill);
                    proxy.visual.Brush(proxy.brush);
                    for(auto& shadow:proxy.shadow_effects)shadow.Mask(proxy.brush);
                    proxy.width = crop.width; proxy.height = crop.height;
                }
                vw::CompositedFrame region;
                check_hresult(vw::MakeCompositedRegion(decoded, {tile.atlas_x, tile.atlas_y, static_cast<unsigned>(crop.width), static_cast<unsigned>(crop.height)}, &region));
                auto drawing = proxy.surface.as<ABI::Windows::UI::Composition::ICompositionDrawingSurfaceInterop>();
                com_ptr<ID3D11Texture2D> destination; POINT offset{};
                check_hresult(drawing->BeginDraw(nullptr, __uuidof(ID3D11Texture2D), destination.put_void(), &offset));
                const auto copy = offset.x < 0 || offset.y < 0 ? E_INVALIDARG
                    : vw::CopyCompositedRegion(decoder->context(), region, destination.get(), static_cast<unsigned>(offset.x), static_cast<unsigned>(offset.y));
                const auto ended = drawing->EndDraw(); check_hresult(copy); check_hresult(ended);
            }
            resize_visual(proxy);
            if (!proxy.shown) { ShowWindow(proxy.window, SW_SHOWNOACTIVATE); proxy.shown=true; }
            sync_shadow(proxy);visibility(proxy);source_drag(proxy);
        }
        decoder->context()->Flush();
        for (auto it = windows.begin(); it != windows.end();) {
            if (!live.contains(it->first)) { send(it->first, vf::InputKind::release); it = windows.erase(it); }
            else ++it;
        }
    }
    void frame(vf::Frame frame) {
        active_lane=frame.activity_epoch?frame.activity_lane:0;
        auto& lane=lanes[active_lane];auto& decoder=lane.decoder;
        auto& pending=lane.pending;auto& pending_alpha=lane.pending_alpha;
        auto& cached_alpha=lane.cached_alpha;auto& encoded_alpha=lane.encoded_alpha;
        auto& alpha_width=lane.alpha_width;auto& alpha_height=lane.alpha_height;
        if (frame.codec != 1) throw std::runtime_error("Windows window presenter requires H264; configure macOS --codec h264");
        if (!decoder) { if (!frame.keyframe) return; prepare(); }
        const auto identity = ++decode_sequence;
        const auto started=std::chrono::steady_clock::now();
        if(!cached_alpha || alpha_width!=frame.width || alpha_height!=frame.height || encoded_alpha!=frame.alpha) {
            cached_alpha=std::make_shared<const std::vector<uint8_t>>(vf::decode_alpha(frame.alpha,static_cast<size_t>(frame.width)*frame.height));
            encoded_alpha=frame.alpha;alpha_width=frame.width;alpha_height=frame.height;++alpha_updates;
        }
        pending_alpha[identity]=cached_alpha;
        if (pending.size() >= 32) throw std::runtime_error("decoder produced no output; resetting local codec");
        const auto width = frame.width, height = frame.height;
        pending.emplace(identity, std::move(frame));
        std::vector<vw::CompositedFrame> completed;
        check_hresult(decoder->Submit(identity, pending.at(identity).color, {identity, width, height, *cached_alpha,cached_alpha}, &completed));
        const auto decoded_at=std::chrono::steady_clock::now();
        for (const auto& decoded : completed) {
            auto it = pending.find(decoded.frame_identity);
            if (it == pending.end() || decoded.width != it->second.width || decoded.height != it->second.height)
                throw std::runtime_error("decoded window/frame geometry mismatch");
            present(it->second, decoded); pending.erase(it);pending_alpha.erase(decoded.frame_identity);
        }
        const auto finished=std::chrono::steady_clock::now();
        statistics_decode_ms+=std::chrono::duration<double,std::milli>(decoded_at-started).count();
        statistics_present_ms+=std::chrono::duration<double,std::milli>(finished-decoded_at).count();++statistics_frames;
        if(finished-statistics_start>=std::chrono::seconds(5)) {
            std::fprintf(stderr,"windows-window-stats frames=%llu decode-submit-mean-ms=%.3f present-submit-mean-ms=%.3f alpha-updates-total=%llu atlas=%ux%u windows=%zu\n",
                static_cast<unsigned long long>(statistics_frames),statistics_decode_ms/statistics_frames,statistics_present_ms/statistics_frames,
                static_cast<unsigned long long>(alpha_updates),width,height,windows.size());
            statistics_start=finished;statistics_frames=0;statistics_decode_ms=statistics_present_ms=0;
        }
    }
    void pump() {
        if (!reader || pumping) return;
        pumping = true;
        for (auto& [id, proxy] : windows) if (proxy->geometry_queued) geometry(*proxy);
        if (auto next = reader->take()) {
            try { frame(std::move(*next)); }
            catch (const hresult_error& error) { std::fprintf(stderr, "window GPU recovering: %s\n", to_string(error.message()).c_str()); ++validation_errors; reset_lane(); }
            catch (const std::exception& error) { std::fprintf(stderr, "window presentation recovering: %s\n", error.what()); ++validation_errors; reset_lane(); }
        }
        pumping = false;
    }
    void finish() {
        for(active_lane=0;active_lane<2;++active_lane){
        auto& lane=lanes[active_lane];auto& decoder=lane.decoder;
        auto& pending=lane.pending;auto& pending_alpha=lane.pending_alpha;
        if (!decoder) continue;
        std::vector<vw::CompositedFrame> completed;
        check_hresult(decoder->Finish(&completed));
        for (const auto& decoded : completed) {
            auto it = pending.find(decoded.frame_identity);
            if (it == pending.end() || decoded.width != it->second.width || decoded.height != it->second.height)
                throw std::runtime_error("drained window/frame geometry mismatch");
            present(it->second, decoded); pending.erase(it);pending_alpha.erase(decoded.frame_identity);
        }
        if (validate && !pending.empty()) throw std::runtime_error("validation left undecoded window frames");
        }
        active_lane=0;
    }
};
}
int main(int argc, char* argv[]) {
    if(argc==2 && std::string_view(argv[1])=="--activity-priority-capabilities") { _setmode(_fileno(stdout), _O_BINARY); std::puts("activity-priority-v1"); return 0; }
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
        cls.lpfnWndProc=DefWindowProcW;cls.lpszClassName=L"ViewflowPortableShadow";
        if(!RegisterClassW(&cls))throw_last_error();
        Reader reader(&app.output); app.reader = &reader;
        bool running = true;
        auto last_visibility = std::chrono::steady_clock::now();
        while (running && !app.output.stopped) {
            MSG message{};
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
                if (message.message == WM_QUIT) { running = false; break; }
                TranslateMessage(&message); DispatchMessageW(&message);
            }
            for (auto& [id, proxy] : app.windows) { if (proxy->geometry_queued) app.geometry(*proxy); }
            app.poll_source_drags();
            const auto now = std::chrono::steady_clock::now();
            if (now-last_visibility >= std::chrono::milliseconds(100)) {
                for (auto& [id, proxy] : app.windows) app.visibility(*proxy);
                last_visibility=now;
            }
            if (auto frame = reader.take()) {
                try { app.frame(std::move(*frame)); }
                catch (const hresult_error& error) { std::fprintf(stderr, "window GPU recovering: %s\n", to_string(error.message()).c_str()); ++app.validation_errors; app.reset_lane(); }
                catch (const std::exception& error) { std::fprintf(stderr, "window presentation recovering: %s\n", error.what()); ++app.validation_errors; app.reset_lane(); }
            } else if (reader.ended) break;
            else MsgWaitForMultipleObjects(0, nullptr, FALSE, 5, QS_ALLINPUT);
        }
        if (reader.ended) app.finish();
        if (app.validate && (app.decoded_count == 0 || app.validation_errors)) throw std::runtime_error("window decoder validation failed");
        return 0;
    } catch (const hresult_error& error) { std::fprintf(stderr, "windows presenter: %s\n", to_string(error.message()).c_str()); return 1; }
    catch (const std::exception& error) { std::fprintf(stderr, "windows presenter: %s\n", error.what()); return 1; }
}
