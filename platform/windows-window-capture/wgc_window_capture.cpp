#include "wgc_window_capture.hpp"
#ifdef _MSC_VER
// Shared diagnostics reads fixed startup environment settings with getenv.
// Keep the CRT compatibility exception scoped to that header.
#pragma warning(push)
#pragma warning(disable:4996)
#endif
#include "../reverse-common/diagnostics.hpp"
#ifdef _MSC_VER
#pragma warning(pop)
#endif

#include <d3d11_4.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.Metadata.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Security.Authorization.AppCapabilityAccess.h>
#include <winrt/base.h>

#include <atomic>
#include <mutex>
#include <thread>
#include <utility>
#include <chrono>
#include <cstdio>

namespace viewflow::windows_capture {
namespace {

using winrt::Windows::Graphics::SizeInt32;
using winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool;
using winrt::Windows::Graphics::Capture::GraphicsCaptureItem;
using winrt::Windows::Graphics::Capture::GraphicsCaptureSession;
using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
using winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;

constexpr auto kPixelFormat = DirectXPixelFormat::B8G8R8A8UIntNormalized;
std::int32_t configuredFramePoolBuffers() noexcept {
    wchar_t value[8]{};
    if(GetEnvironmentVariableW(L"VIEWFLOW_WGC_BUFFERS",value,8)==1){
        if(value[0]==L'1')return 1;
        if(value[0]==L'3')return 3;
    }
    return 2;
}

void configureCaptureInterval(const GraphicsCaptureSession& session) noexcept {
    try {
        if(!winrt::Windows::Foundation::Metadata::ApiInformation::IsPropertyPresent(
            L"Windows.Graphics.Capture.GraphicsCaptureSession",L"MinUpdateInterval")) {
            std::fprintf(stderr,"wgc_interval supported=0\n");return;
        }
        const auto before=session.MinUpdateInterval();
        wchar_t value[16]{};
        const auto length=GetEnvironmentVariableW(L"VIEWFLOW_WGC_INTERVAL_US",value,16);
        const int requested=length==1 && value[0]==L'0'?0:length==4 && wcscmp(value,L"4000")==0?4000:length==4 && wcscmp(value,L"1000")==0?1000:-1;
        if(requested>=0)session.MinUpdateInterval(std::chrono::microseconds(requested));
        std::fprintf(stderr,"wgc_interval supported=1 requested_us=%d before_100ns=%lld after_100ns=%lld\n",requested,
            static_cast<long long>(before.count()),static_cast<long long>(session.MinUpdateInterval().count()));
    }catch(const winrt::hresult_error& error) {
        std::fprintf(stderr,"wgc_interval unavailable_hresult=%08lx retaining_capture=1\n",static_cast<unsigned long>(error.code()));
    }catch(...) {
        std::fprintf(stderr,"wgc_interval unavailable retaining_capture=1\n");
    }
}

// Keep the session alive across the OS access request without blocking capture
// startup. A closed session or denied borderless access must not end streaming.
winrt::fire_and_forget requestBorderlessCapture(GraphicsCaptureSession session) {
    try {
        session.IsBorderRequired(false);
        co_await winrt::Windows::Graphics::Capture::GraphicsCaptureAccess::RequestAccessAsync(
            winrt::Windows::Graphics::Capture::GraphicsCaptureAccessKind::Borderless);
        session.IsBorderRequired(false);
    } catch (const winrt::hresult_error&) {
        OutputDebugStringW(L"Viewflow: borderless capture unavailable; retaining capture.\n");
    } catch (...) {
        OutputDebugStringW(L"Viewflow: borderless capture request failed; retaining capture.\n");
    }
}

NativeWindowBounds readBounds(HWND window) noexcept {
    RECT rect{};
    NativeWindowBounds result{};
    if (SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS,
                                        &rect, sizeof(rect)))) {
        result.is_extended_frame_bounds = true;
    } else if (!GetWindowRect(window, &rect)) {
        return result;
    }
    result.left = rect.left;
    result.top = rect.top;
    result.right = rect.right;
    result.bottom = rect.bottom;
    return result;
}

IDirect3DDevice createDirect3DDevice(winrt::com_ptr<ID3D11Device>& d3d_device,
                                    ID3D11Device* shared_device) {
    static constexpr D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
    };
    D3D_FEATURE_LEVEL selected{};
    if (shared_device) {
        d3d_device.copy_from(shared_device);
    } else {
    winrt::check_hresult(D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, ARRAYSIZE(levels),
        D3D11_SDK_VERSION, d3d_device.put(), &selected, nullptr));
    }

    const auto multithread = d3d_device.as<ID3D11Multithread>();
    multithread->SetMultithreadProtected(TRUE);
    if (!multithread->GetMultithreadProtected()) winrt::throw_hresult(E_FAIL);

    const auto dxgi_device = d3d_device.as<IDXGIDevice>();
    // Diagnostic relative-priority control; unset leaves the device untouched.
    // A shared device also carries the source copy work, not only WGC work.
    wchar_t priority_value[2]{};
    const auto priority_length=GetEnvironmentVariableW(L"VIEWFLOW_WGC_GPU_PRIORITY",priority_value,2);
    if(priority_length==1 && (priority_value[0]==L'0' || priority_value[0]==L'7')) {
        const int requested=priority_value[0]-L'0';int before{},after{};
        const auto before_hr=dxgi_device->GetGPUThreadPriority(&before);
        const auto set_hr=dxgi_device->SetGPUThreadPriority(requested);
        const auto after_hr=dxgi_device->GetGPUThreadPriority(&after);
        std::fprintf(stderr,"wgc_gpu_priority requested=%d before=%d after=%d before_hr=0x%08lx set_hr=0x%08lx after_hr=0x%08lx shared_device=%u scope=relative-device-priority\n",requested,before,after,static_cast<unsigned long>(before_hr),static_cast<unsigned long>(set_hr),static_cast<unsigned long>(after_hr),unsigned(shared_device!=nullptr));
    } else if(priority_length) {
        std::fprintf(stderr,"wgc_gpu_priority ignored=invalid-option accepted=0,7\n");
    }
    IDirect3DDevice result{nullptr};
    winrt::check_hresult(::CreateDirect3D11DeviceFromDXGIDevice(
        dxgi_device.get(), reinterpret_cast<::IInspectable**>(winrt::put_abi(result))));
    return result;
}

GraphicsCaptureItem createItemForWindow(HWND window) {
    const auto factory =
        winrt::get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
    GraphicsCaptureItem item{nullptr};
    winrt::check_hresult(factory->CreateForWindow(
        window, winrt::guid_of<GraphicsCaptureItem>(), winrt::put_abi(item)));
    return item;
}

std::uint32_t asUnsignedHresult(HRESULT value) noexcept {
    return static_cast<std::uint32_t>(value);
}

struct CaptureState {
    std::atomic<bool> poll_stop{false};
    std::thread poll_thread;
    std::uint64_t poll_acquired=0,event_acquired=0,poll_empty=0,event_empty=0;
    std::mutex state_mutex;
    // Prevents stop from closing WGC resources while a callback has a borrowed
    // surface. Callbacks must therefore not synchronously call stop().
    std::mutex delivery_mutex;
    std::atomic<bool> terminal{false};
    HWND window = nullptr;
    CaptureLimits limits{};
    FrameCallbacks callbacks{};
    winrt::com_ptr<ID3D11Device> d3d_device;
    IDirect3DDevice winrt_device{nullptr};
    GraphicsCaptureItem item{nullptr};
    Direct3D11CaptureFramePool frame_pool{nullptr};
    const std::int32_t frame_pool_buffers=configuredFramePoolBuffers();
    GraphicsCaptureSession session{nullptr};
    winrt::event_token frame_arrived{};
    winrt::event_token item_closed{};
    bool handlers_installed = false;
    SizeInt32 pool_size{};
    CaptureGeometry geometry{};
    const bool delivery_trace=[] {wchar_t value[2]{};return GetEnvironmentVariableW(L"VIEWFLOW_WGC_DELIVERY_TRACE",value,2)==1 && value[0]==L'1';}();
    bool latest_frame=[] {wchar_t value[2]{};return GetEnvironmentVariableW(L"VIEWFLOW_WGC_LATEST",value,2)==1 && value[0]==L'1';}();
    std::uint64_t latest_callbacks=0,latest_skipped=0;
    bool dirty_probe=false;
    std::uint64_t dirty_probe_frames=0;
};

void terminal(const std::shared_ptr<CaptureState>& state, CaptureFailure failure,
              HRESULT hresult) noexcept {
    bool expected = false;
    if (!state->terminal.compare_exchange_strong(expected, true)) return;
    try {
        if (state->callbacks.on_terminal) {
            state->callbacks.on_terminal(failure, asUnsignedHresult(hresult));
        }
    } catch (...) {
        // Terminal reporting is observational; it must not re-enter WGC.
    }
}

CaptureGeometry updateGeometry(const std::shared_ptr<CaptureState>& state,
                               SizeInt32 size, bool& changed) noexcept {
    std::scoped_lock lock(state->state_mutex);
    const CaptureGeometry proposed{
        0,
        static_cast<std::uint32_t>(size.Width),
        static_cast<std::uint32_t>(size.Height),
        readBounds(state->window),
    };
    changed = state->geometry.epoch == 0 ||
              state->geometry.content_width != proposed.content_width ||
              state->geometry.content_height != proposed.content_height ||
              state->geometry.source_bounds != proposed.source_bounds;
    if (changed) {
        const auto epoch = nextGeometryEpoch(state->geometry.epoch, true);
        if (epoch == 0) return {};
        state->geometry = proposed;
        state->geometry.epoch = epoch;
    }
    return state->geometry;
}

void reportGeometry(const std::shared_ptr<CaptureState>& state,
                    const CaptureGeometry& geometry) noexcept {
    try {
        if (state->callbacks.on_geometry) state->callbacks.on_geometry(geometry);
    } catch (...) {
        terminal(state, CaptureFailure::consumer_failed, E_FAIL);
    }
}

void onFrame(const std::shared_ptr<CaptureState>& state,
             const Direct3D11CaptureFramePool& sender,bool from_poll=false) noexcept {
    const auto clock=[] {LARGE_INTEGER q{},f{};QueryPerformanceCounter(&q);QueryPerformanceFrequency(&f);return q.QuadPart/f.QuadPart*10000000+(q.QuadPart%f.QuadPart)*10000000/f.QuadPart;};
    CapturedFrame::DeliveryTiming timing{};
    if(state->delivery_trace)timing.entered=clock();
    std::scoped_lock delivery_lock(state->delivery_mutex);
    if(state->delivery_trace)timing.locked=clock();
    if (state->terminal.load()) return;
    try {
        auto frame = sender.TryGetNextFrame();
        if (!frame) {
            if(state->delivery_trace)++(from_poll?state->poll_empty:state->event_empty);
            return;
        }
        if(state->delivery_trace){
            timing.acquired=clock();++(from_poll?state->poll_acquired:state->event_acquired);
            // Do not write stderr while holding the frame-delivery lock.
            // Pipe backpressure can otherwise stall capture for whole refreshes.
        }
        // Bounded drain: keep one complete newest snapshot, retaining its own
        // size/timestamp. Do not spin waiting for a newer capture to arrive.
        if(state->latest_frame){
            unsigned skipped=0;
            for(std::int32_t i=1;i<state->frame_pool_buffers;++i){
                auto newer=sender.TryGetNextFrame();if(!newer)break;
                frame.Close();frame=std::move(newer);++skipped;
            }
            state->latest_skipped+=skipped;
            if(++state->latest_callbacks%120==0)
                vf_diag::trace("wgc_latest callbacks=%llu skipped=%llu\n",static_cast<unsigned long long>(state->latest_callbacks),static_cast<unsigned long long>(state->latest_skipped));
        }
        const auto content_size = frame.ContentSize();
        const auto width = static_cast<std::uint32_t>(content_size.Width);
        const auto height = static_cast<std::uint32_t>(content_size.Height);
        if (!validContentExtent(width, height, state->limits)) {
            terminal(state, CaptureFailure::invalid_frame_extent, E_FAIL);
            return;
        }

        const bool resized = content_size.Width != state->pool_size.Width ||
                             content_size.Height != state->pool_size.Height;
        if (resized) {
            // The old allocation can contain clipped/undefined pixels. Drop
            // this transitional frame, return it to WGC, then recreate.
            frame = nullptr;
            sender.Recreate(state->winrt_device, kPixelFormat, state->frame_pool_buffers,
                            content_size);
            state->pool_size = content_size;
            bool changed = false;
            const auto geometry = updateGeometry(state, content_size, changed);
            if (geometry.epoch == 0) {
                terminal(state, CaptureFailure::runtime_failed, E_FAIL);
                return;
            }
            if (changed) reportGeometry(state, geometry);
            return;
        }

        bool geometry_changed = false;
        const auto geometry = updateGeometry(state, content_size, geometry_changed);
        if (geometry.epoch == 0) {
            terminal(state, CaptureFailure::runtime_failed, E_FAIL);
            return;
        }
        if (geometry_changed) reportGeometry(state, geometry);
        if (state->terminal.load()) return;

        if(state->delivery_trace)timing.geometry_done=clock();
        const auto access = frame.Surface().as<
            ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
        winrt::com_ptr<ID3D11Texture2D> texture;
        winrt::check_hresult(access->GetInterface(winrt::guid_of<ID3D11Texture2D>(),
                                                  texture.put_void()));
        if (!state->callbacks.on_frame) return;
        if(state->dirty_probe && state->dirty_probe_frames++%120==0) {
            try {
                const auto regions=frame.DirtyRegions();
                std::uint64_t area=0;
                for(const auto& rect:regions)if(rect.Width>0 && rect.Height>0)
                    area+=std::uint64_t(rect.Width)*std::uint64_t(rect.Height);
                vf_diag::trace("wgc_dirty_probe frame=%llu mode=%d rectangles=%u summed_pixels=%llu content_pixels=%llu scope=sum-may-overlap\n",
                    static_cast<unsigned long long>(state->dirty_probe_frames),int(frame.DirtyRegionMode()),regions.Size(),
                    static_cast<unsigned long long>(area),static_cast<unsigned long long>(std::uint64_t(geometry.content_width)*geometry.content_height));
            }catch(...) {
                state->dirty_probe=false;
                vf_diag::trace("wgc_dirty_probe unavailable retaining_full_capture=1\n");
            }
        }
        // C++/WinRT projects TimeSpan as std::chrono::duration. count() is the
        // raw ABI Duration count in 100 ns units, not a converted wall clock.
        const auto system_relative_time_100ns = frame.SystemRelativeTime().count();
        if (!validSystemRelativeTime100ns(system_relative_time_100ns)) {
            terminal(state, CaptureFailure::runtime_failed, E_FAIL);
            return;
        }
        if(state->delivery_trace)timing.surface_ready=clock();
        const CapturedFrame captured{
            texture.get(), geometry, system_relative_time_100ns,
            CapturedAlpha::bgra8_alpha_preserved_unknown_mode,timing};
        try {
            state->callbacks.on_frame(captured);
        } catch (...) {
            terminal(state, CaptureFailure::consumer_failed, E_FAIL);
        }
    } catch (const winrt::hresult_error& error) {
        terminal(state, CaptureFailure::runtime_failed, error.code());
    } catch (...) {
        terminal(state, CaptureFailure::runtime_failed, E_FAIL);
    }
}

void closeState(const std::shared_ptr<CaptureState>& state) noexcept {
    if (!state) return;
    // Stop polling before taking locks used by onFrame; never join under them.
    state->poll_stop.store(true);
    if(state->poll_thread.joinable())state->poll_thread.join();
    std::scoped_lock delivery_lock(state->delivery_mutex);
    std::scoped_lock state_lock(state->state_mutex);
    try {
        if (state->handlers_installed) {
            state->frame_pool.FrameArrived(state->frame_arrived);
            state->item.Closed(state->item_closed);
            state->handlers_installed = false;
        }
        if (state->session) state->session.Close();
        if (state->frame_pool) state->frame_pool.Close();
    } catch (...) {
        // Destruction cannot surface a late Close error.
    }
    state->session = nullptr;
    state->frame_pool = nullptr;
    state->item = nullptr;
    state->winrt_device = nullptr;
    state->d3d_device = nullptr;
    if(state->delivery_trace && (state->poll_acquired || state->event_acquired)) {
        std::fprintf(stderr,"wgc_delivery_origin poll=%llu event=%llu poll_empty=%llu event_empty=%llu scope=closed-capture-acquired-frame-not-earliness\n",
            static_cast<unsigned long long>(state->poll_acquired),static_cast<unsigned long long>(state->event_acquired),
            static_cast<unsigned long long>(state->poll_empty),static_cast<unsigned long long>(state->event_empty));
        state->poll_acquired=state->event_acquired=state->poll_empty=state->event_empty=0;
    }
    state->terminal.store(true);
}

} // namespace

struct WindowCapture::Impl {
    mutable std::mutex owner_mutex;
    std::shared_ptr<CaptureState> state;
};

WindowCapture::WindowCapture() : impl_(std::make_unique<Impl>()) {}

WindowCapture::~WindowCapture() { stop(); }

StartResult WindowCapture::start(HWND window, CaptureLimits limits,
                                 FrameCallbacks callbacks, ID3D11Device* shared_device) {
    stop();
    if (!IsWindow(window)) return {CaptureFailure::invalid_window, 0};
    if (limits.max_width == 0 || limits.max_height == 0 || limits.max_pixels == 0) {
        return {CaptureFailure::invalid_frame_extent, 0};
    }

    std::shared_ptr<CaptureState> state;
    CaptureFailure failure_stage = CaptureFailure::setup_failed;
    try {
        if (!GraphicsCaptureSession::IsSupported()) {
            return {CaptureFailure::platform_unsupported, 0};
        }
        state = std::make_shared<CaptureState>();
        state->window = window;
        state->limits = limits;
        state->callbacks = std::move(callbacks);
        failure_stage = CaptureFailure::d3d_device_unavailable;
        state->winrt_device = createDirect3DDevice(state->d3d_device, shared_device);
        failure_stage = CaptureFailure::setup_failed;
        state->item = createItemForWindow(window);
        state->pool_size = state->item.Size();
        if (!validContentExtent(static_cast<std::uint32_t>(state->pool_size.Width),
                                static_cast<std::uint32_t>(state->pool_size.Height),
                                limits)) {
            closeState(state);
            return {CaptureFailure::invalid_frame_extent, 0};
        }
        bool initial_geometry_changed = false;
        const auto initial_geometry =
            updateGeometry(state, state->pool_size, initial_geometry_changed);
        if (initial_geometry.epoch == 0) {
            closeState(state);
            return {CaptureFailure::runtime_failed, asUnsignedHresult(E_FAIL)};
        }
        state->frame_pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            state->winrt_device, kPixelFormat, state->frame_pool_buffers, state->pool_size);
        std::fprintf(stderr,"wgc_frame_pool buffers=%d\n",state->frame_pool_buffers);
        state->session = state->frame_pool.CreateCaptureSession(state->item);
        configureCaptureInterval(state->session);
        wchar_t dirty_probe_value[2]{};
        if(GetEnvironmentVariableW(L"VIEWFLOW_WGC_DIRTY_PROBE",dirty_probe_value,2)==1 && dirty_probe_value[0]==L'1') {
            state->dirty_probe=winrt::Windows::Foundation::Metadata::ApiInformation::IsPropertyPresent(
                L"Windows.Graphics.Capture.Direct3D11CaptureFrame",L"DirtyRegions");
            std::fprintf(stderr,"wgc_dirty_probe supported=%u\n",unsigned(state->dirty_probe));
        }
        // Receiver draws the pointer locally; do not bake it into a window.
        state->session.IsCursorCaptureEnabled(false);
        requestBorderlessCapture(state->session);
        state->frame_arrived = state->frame_pool.FrameArrived(
            [state](const Direct3D11CaptureFramePool& sender,
                    const winrt::Windows::Foundation::IInspectable&) {
                onFrame(state, sender);
            });
        state->item_closed = state->item.Closed(
            [state](const GraphicsCaptureItem&,
                    const winrt::Windows::Foundation::IInspectable&) {
                std::scoped_lock delivery_lock(state->delivery_mutex);
                terminal(state, CaptureFailure::target_closed, S_OK);
            });
        state->handlers_installed = true;
        state->session.StartCapture();
        wchar_t poll_option[2]{};
        if(GetEnvironmentVariableW(L"VIEWFLOW_WGC_POLL_READY",poll_option,2)==1 && poll_option[0]==L'1') {
            state->poll_thread=std::thread([state]{
                try {
                    winrt::init_apartment(winrt::apartment_type::multi_threaded);
                    while(!state->poll_stop.load() && !state->terminal.load()) {
                        onFrame(state,state->frame_pool,true);
                        Sleep(1);
                    }
                    winrt::uninit_apartment();
                } catch(...) {
                    // Optional probe failure leaves the normal event path alive.
                    std::fprintf(stderr,"wgc_poll_ready unavailable event_path_retained=1\n");
                }
            });
            std::fprintf(stderr,"wgc_poll_ready enabled=1 sleep_ms=1 event_path_retained=1\n");
        }

        {
            std::scoped_lock lock(impl_->owner_mutex);
            impl_->state = state;
        }
        if (initial_geometry_changed) reportGeometry(state, initial_geometry);
        if (state->terminal.load()) {
            stop();
            return {CaptureFailure::consumer_failed, asUnsignedHresult(E_FAIL)};
        }
        return {};
    } catch (const winrt::hresult_error& error) {
        const auto hr = asUnsignedHresult(error.code());
        closeState(state);
        return {failure_stage == CaptureFailure::d3d_device_unavailable
                    ? failure_stage
                    : classifyStartupHresult(hr),
                hr};
    } catch (...) {
        closeState(state);
        return {CaptureFailure::runtime_failed, asUnsignedHresult(E_FAIL)};
    }
}

void WindowCapture::stop() noexcept {
    std::shared_ptr<CaptureState> state;
    {
        std::scoped_lock lock(impl_->owner_mutex);
        state = std::move(impl_->state);
    }
    closeState(state);
}

bool WindowCapture::running() const noexcept {
    std::scoped_lock lock(impl_->owner_mutex);
    return impl_->state && !impl_->state->terminal.load();
}

} // namespace viewflow::windows_capture
