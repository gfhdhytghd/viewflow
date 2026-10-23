// Read-only output enumeration; desktop duplication is explicitly selected.
// No pixels are copied, mapped, dumped or retained beyond the acquired frame.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <limits>
using Microsoft::WRL::ComPtr;
namespace {
void result(const char* stage, HRESULT hr) {
    std::printf("%s hr=0x%08lx\n", stage, static_cast<unsigned long>(hr));
}
bool index_arg(const char* arg, UINT& value) {
    if (!arg || !*arg || *arg < '0' || *arg > '9') return false;
    errno = 0; char* end = nullptr;
    const unsigned long parsed = std::strtoul(arg, &end, 10);
    if (errno || end == arg || *end || parsed > std::numeric_limits<UINT>::max()) return false;
    value = static_cast<UINT>(parsed); return true;
}
int capture(IDXGIAdapter1* adapter, IDXGIOutput* output) {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    D3D_FEATURE_LEVEL selected{};
    HRESULT hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
        device.GetAddressOf(), &selected, context.GetAddressOf());
    result("D3D11CreateDevice(selected adapter)", hr); if (FAILED(hr)) return 1;
    ComPtr<IDXGIOutput1> output1;
    hr = output->QueryInterface(IID_PPV_ARGS(output1.GetAddressOf()));
    result("QueryInterface(IDXGIOutput1)", hr); if (FAILED(hr)) return 1;
    ComPtr<IDXGIOutputDuplication> duplication;
    hr = output1->DuplicateOutput(device.Get(), duplication.GetAddressOf());
    result("DuplicateOutput", hr);
    if (FAILED(hr)) {
        result("GetDeviceRemovedReason", device->GetDeviceRemovedReason());
        std::printf("capture=unavailable interactive_session_may_be_required=1 transport_status=untested\n");
        return 1;
    }
    DXGI_OUTDUPL_DESC duplication_desc{};
    duplication->GetDesc(&duplication_desc);
    std::printf("duplication width=%u height=%u format=%u rotation=%u desktop_in_system_memory=%u\n",
        duplication_desc.ModeDesc.Width, duplication_desc.ModeDesc.Height,
        unsigned(duplication_desc.ModeDesc.Format), unsigned(duplication_desc.Rotation),
        unsigned(duplication_desc.DesktopImageInSystemMemory));
    DXGI_OUTDUPL_FRAME_INFO info{};
    ComPtr<IDXGIResource> frame;
    hr = duplication->AcquireNextFrame(1000, &info, frame.GetAddressOf());
    result("AcquireNextFrame(timeout_ms=1000)", hr);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
        std::printf("capture=pending reason=no-new-frame transport_failure=0\n");
        return 0;
    }
    if (FAILED(hr)) { result("GetDeviceRemovedReason", device->GetDeviceRemovedReason()); return 1; }
    ComPtr<ID3D11Texture2D> texture;
    const HRESULT texture_hr = frame.As(&texture);
    result("QueryInterface(frame ID3D11Texture2D)", texture_hr);
    if (SUCCEEDED(texture_hr)) {
        D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
        std::printf("frame width=%u height=%u format=%u mip_levels=%u array_size=%u sample_count=%u "
            "usage=%u bind_flags=0x%x cpu_access_flags=0x%x misc_flags=0x%x shared=%u shared_nt=%u shared_keyed_mutex=%u "
            "last_present_qpc=%lld accumulated_frames=%u rects_coalesced=%u protected_content_masked=%u\n",
            desc.Width, desc.Height, unsigned(desc.Format), desc.MipLevels, desc.ArraySize, desc.SampleDesc.Count,
            unsigned(desc.Usage), desc.BindFlags, desc.CPUAccessFlags, desc.MiscFlags,
            unsigned((desc.MiscFlags & D3D11_RESOURCE_MISC_SHARED) != 0),
            unsigned((desc.MiscFlags & D3D11_RESOURCE_MISC_SHARED_NTHANDLE) != 0),
            unsigned((desc.MiscFlags & D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX) != 0),
            static_cast<long long>(info.LastPresentTime.QuadPart), info.AccumulatedFrames,
            unsigned(info.RectsCoalesced), unsigned(info.ProtectedContentMaskedOut));
    }
    // Drop texture references before releasing duplication frame ownership.
    texture.Reset(); frame.Reset();
    hr = duplication->ReleaseFrame(); result("ReleaseFrame", hr);
    const HRESULT removed = device->GetDeviceRemovedReason(); result("GetDeviceRemovedReason", removed);
    std::printf("capture=%s d12_copy=untested ivshmem_transport=untested performance=unmeasured\n",
        SUCCEEDED(texture_hr) && SUCCEEDED(hr) && SUCCEEDED(removed) ? "acquired-and-released" : "failed");
    return FAILED(texture_hr) || FAILED(hr) || FAILED(removed) ? 1 : 0;
}
}
int main(int argc, char** argv) {
    // Report physical output coordinates rather than DPI-virtualized pixels.
    const BOOL dpi_aware=SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const DWORD dpi_error=dpi_aware?0:GetLastError();
    bool do_capture = false; UINT requested_adapter = 0, requested_output = 0;
    const char* log_path = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--capture-output") && !do_capture && i + 2 < argc) {
            if (!index_arg(argv[i + 1], requested_adapter) || !index_arg(argv[i + 2], requested_output)) return 2;
            do_capture = true; i += 2;
        } else if (!std::strcmp(argv[i], "--log") && !log_path && i + 1 < argc) {
            log_path = argv[++i];
        } else {
            std::fprintf(stderr, "Usage: viewflow_d12_desktop_output_probe [--capture-output <adapter-index> <output-index>] [--log <path>]\n");
            return 2;
        }
    }
    if (log_path) {
        FILE* stream = nullptr;
        if (freopen_s(&stream, log_path, "w", stdout)) {
            std::fprintf(stderr, "Cannot open output log\n"); return 1;
        }
    }
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("dpi_per_monitor_v2=%u error=%lu\n",unsigned(dpi_aware),dpi_error);
    std::printf("scope=%s no_input=1 no_focus=1 no_pixel_dump=1 no_mode_change=1\n",
        do_capture ? "explicit-single-output-acquire" : "output-enumeration-only");
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()));
    result("CreateDXGIFactory1", hr); if (FAILED(hr)) return 1;
    ComPtr<IDXGIAdapter1> selected_adapter;
    ComPtr<IDXGIOutput> selected_output;
    for (UINT ai = 0;; ++ai) {
        ComPtr<IDXGIAdapter1> adapter;
        hr = factory->EnumAdapters1(ai, adapter.GetAddressOf());
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr)) { result("EnumAdapters1", hr); return 1; }
        DXGI_ADAPTER_DESC1 desc{};
        hr = adapter->GetDesc1(&desc); result("Adapter::GetDesc1", hr); if (FAILED(hr)) return 1;
        if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
        char name[512]{};
        WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof(name), nullptr, nullptr);
        std::printf("adapter index=%u name=\"%s\" luid=%08lx:%08lx vendor=0x%x device=0x%x\n",
            ai, name, static_cast<unsigned long>(desc.AdapterLuid.HighPart),
            static_cast<unsigned long>(desc.AdapterLuid.LowPart), desc.VendorId, desc.DeviceId);
        for (UINT oi = 0;; ++oi) {
            ComPtr<IDXGIOutput> output;
            hr = adapter->EnumOutputs(oi, output.GetAddressOf());
            if (hr == DXGI_ERROR_NOT_FOUND) break;
            if (FAILED(hr)) { result("EnumOutputs", hr); return 1; }
            DXGI_OUTPUT_DESC out{};
            hr = output->GetDesc(&out); result("Output::GetDesc", hr); if (FAILED(hr)) return 1;
            char display[128]{};
            WideCharToMultiByte(CP_UTF8, 0, out.DeviceName, -1, display, sizeof(display), nullptr, nullptr);
            std::printf("output adapter=%u index=%u device_name=\"%s\" attached=%u rect=%ld,%ld,%ld,%ld rotation=%u\n",
                ai, oi, display, unsigned(out.AttachedToDesktop), out.DesktopCoordinates.left,
                out.DesktopCoordinates.top, out.DesktopCoordinates.right, out.DesktopCoordinates.bottom,
                unsigned(out.Rotation));
            if (do_capture && ai == requested_adapter && oi == requested_output) {
                selected_adapter = adapter; selected_output = output;
            }
        }
    }
    if (!do_capture) return 0;
    if (!selected_adapter || !selected_output) {
        std::fprintf(stdout, "requested_output=not-found adapter=%u output=%u\n", requested_adapter, requested_output);
        return 1;
    }
    return capture(selected_adapter.Get(), selected_output.Get());
}
