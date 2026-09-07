#include "wgc_window_capture.hpp"

#include <d3d11_4.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/base.h>

#include <atomic>
#include <mutex>
#include <utility>

namespace viewflow::windows_capture {
namespace {

using winrt::Windows::Graphics::SizeInt32;
using winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool;
using winrt::Windows::Graphics::Capture::GraphicsCaptureItem;
using winrt::Windows::Graphics::Capture::GraphicsCaptureSession;
using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
using winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;

constexpr auto kPixelFormat = DirectXPixelFormat::B8G8R8A8UIntNormalized;
constexpr std::int32_t kFramePoolBuffers = 2;

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

IDirect3DDevice createDirect3DDevice(winrt::com_ptr<ID3D11Device>& d3d_device) {
    static constexpr D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
    };
    D3D_FEATURE_LEVEL selected{};
    winrt::check_hresult(D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, ARRAYSIZE(levels),
        D3D11_SDK_VERSION, d3d_device.put(), &selected, nullptr));

    const auto multithread = d3d_device.as<ID3D11Multithread>();
    multithread->SetMultithreadProtected(TRUE);
    if (!multithread->GetMultithreadProtected()) winrt::throw_hresult(E_FAIL);

    const auto dxgi_device = d3d_device.as<IDXGIDevice>();
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
    GraphicsCaptureSession session{nullptr};
    winrt::event_token frame_arrived{};
    winrt::event_token item_closed{};
    bool handlers_installed = false;
    SizeInt32 pool_size{};
    CaptureGeometry geometry{};
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
             const Direct3D11CaptureFramePool& sender) noexcept {
    std::scoped_lock delivery_lock(state->delivery_mutex);
    if (state->terminal.load()) return;
    try {
        auto frame = sender.TryGetNextFrame();
        if (!frame) return;
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
            sender.Recreate(state->winrt_device, kPixelFormat, kFramePoolBuffers,
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

        const auto access = frame.Surface().as<
            ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
        winrt::com_ptr<ID3D11Texture2D> texture;
        winrt::check_hresult(access->GetInterface(winrt::guid_of<ID3D11Texture2D>(),
                                                  texture.put_void()));
        if (!state->callbacks.on_frame) return;
        // C++/WinRT projects TimeSpan as std::chrono::duration. count() is the
        // raw ABI Duration count in 100 ns units, not a converted wall clock.
        const auto system_relative_time_100ns = frame.SystemRelativeTime().count();
        if (!validSystemRelativeTime100ns(system_relative_time_100ns)) {
            terminal(state, CaptureFailure::runtime_failed, E_FAIL);
            return;
        }
        const CapturedFrame captured{
            texture.get(), geometry, system_relative_time_100ns,
            CapturedAlpha::bgra8_alpha_preserved_unknown_mode};
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
                                 FrameCallbacks callbacks) {
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
        state->winrt_device = createDirect3DDevice(state->d3d_device);
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
            state->winrt_device, kPixelFormat, kFramePoolBuffers, state->pool_size);
        state->session = state->frame_pool.CreateCaptureSession(state->item);
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
