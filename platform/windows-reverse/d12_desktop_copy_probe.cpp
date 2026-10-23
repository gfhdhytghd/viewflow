// Explicit read-only desktop frame -> direct D3D12 import -> private RAM probe.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <climits>
#include <memory>
#include "d12_external_heap.hpp"
#include "d12_external_copy.hpp"
#include "d12_desktop_capture.hpp"
#include "fullscreen_window_capture.hpp"
using Microsoft::WRL::ComPtr;
namespace {
void loghr(const char* stage, HRESULT hr) { std::printf("%s hr=0x%08lx\n", stage, static_cast<unsigned long>(hr)); }
struct Handle { HANDLE value = nullptr; ~Handle() { if (value) CloseHandle(value); } };
struct Pages { void* ptr = nullptr; ~Pages() { if (ptr) VirtualFree(ptr, 0, MEM_RELEASE); } };
struct Producer {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext4> context;
    ComPtr<ID3D11Fence> fence;
    ComPtr<ID3D11Texture2D> source, staging;
    bool active = false, signaled = false;
    bool drain() {
        if (!active) return true;
        while (true) {
            const HRESULT removed = device->GetDeviceRemovedReason();
            const UINT64 completed = fence->GetCompletedValue();
            if (FAILED(removed) || completed == UINT64_MAX) {
                loghr("producer device removal", FAILED(removed) ? removed : DXGI_ERROR_DEVICE_REMOVED);
                active = false; return false;
            }
            if (signaled && completed >= 1) { active = false; return true; }
            if (!signaled) { signaled = SUCCEEDED(context->Signal(fence.Get(), 1)); context->Flush(); }
            Sleep(1);
        }
    }
    ~Producer() { drain(); }
};
int run(UINT ai, UINT oi) {
    // Avoid logical-size interpretation of desktop output coordinates.
    const BOOL dpi = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    std::printf("dpi_per_monitor_v2=%u error=%lu\n", unsigned(dpi), dpi ? 0 : GetLastError());
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()));
    loghr("CreateDXGIFactory1", hr); if (FAILED(hr)) return 1;
    ComPtr<IDXGIAdapter1> adapter;
    hr = factory->EnumAdapters1(ai, adapter.GetAddressOf()); loghr("EnumAdapters1(selected)", hr); if (FAILED(hr)) return 1;
    DXGI_ADAPTER_DESC1 ad{};
    hr = adapter->GetDesc1(&ad); loghr("Adapter::GetDesc1", hr); if (FAILED(hr)) return 1;
    if (ad.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) { std::printf("software_adapter=rejected\n"); return 1; }
    ComPtr<IDXGIOutput> output;
    hr = adapter->EnumOutputs(oi, output.GetAddressOf()); loghr("EnumOutputs(selected)", hr); if (FAILED(hr)) return 1;
    DXGI_OUTPUT_DESC od{};
    hr = output->GetDesc(&od); loghr("Output::GetDesc", hr); if (FAILED(hr)) return 1;
    char name[128]{}; WideCharToMultiByte(CP_UTF8, 0, od.DeviceName, -1, name, sizeof(name), nullptr, nullptr);
    std::printf("selected adapter=%u output=%u luid=%08lx:%08lx name=%s attached=%u rect=%ld,%ld,%ld,%ld rotation=%u\n",
        ai, oi, static_cast<unsigned long>(ad.AdapterLuid.HighPart), static_cast<unsigned long>(ad.AdapterLuid.LowPart),
        name, unsigned(od.AttachedToDesktop), od.DesktopCoordinates.left, od.DesktopCoordinates.top,
        od.DesktopCoordinates.right, od.DesktopCoordinates.bottom, unsigned(od.Rotation));
    auto pages = std::make_shared<Pages>();
    Handle fence_handle;
    ComPtr<ID3D11Device> d11;
    ComPtr<ID3D11DeviceContext> context;
    hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, d11.GetAddressOf(), nullptr, context.GetAddressOf());
    loghr("D3D11CreateDevice", hr); if (FAILED(hr)) return 1;
    ComPtr<ID3D11Device5> d115; ComPtr<ID3D11DeviceContext4> c114; ComPtr<ID3D12Device3> d12;
    hr = d11.As(&d115); loghr("QueryInterface(Device5)", hr); if (FAILED(hr)) return 1;
    hr = context.As(&c114); loghr("QueryInterface(Context4)", hr); if (FAILED(hr)) return 1;
    hr = D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(d12.GetAddressOf()));
    loghr("D3D12CreateDevice(Device3)", hr); if (FAILED(hr)) return 1;
    viewflow::reverse::d12::DesktopCapture capture;
    viewflow::reverse::d12::OutputIdentity identity;
    hr=viewflow::reverse::d12::query_output_identity(ad.AdapterLuid,od.DeviceName,identity);
    loghr("QueryDisplayConfig(exact source/target identity)",hr);if(FAILED(hr))return 1;
    std::printf("strict_identity source_id=%u target_id=%u target_luid=%08lx:%08lx\n",identity.source_id,identity.target_id,static_cast<unsigned long>(identity.target_adapter.HighPart),static_cast<unsigned long>(identity.target_adapter.LowPart));
    hr = capture.initialize(d11.Get(), d12.Get(), ad.AdapterLuid, od.DeviceName, &identity);
    loghr("DesktopCapture::initialize(stable LUID/output name)", hr); if (FAILED(hr)) return 1;
    // Lease precedes all consumer guards: they drain before its destruction.
    std::shared_ptr<viewflow::reverse::d12::DesktopCapture::Frame> frame;
    const auto acquired = capture.acquire(frame, 1000);
    loghr("DesktopCapture::acquire", capture.last_error());
    std::printf("desktop_capture diagnostic=%s\n", capture.diagnostic());
    if (acquired == viewflow::reverse::d12::DesktopCapture::Status::pending ||
        acquired == viewflow::reverse::d12::DesktopCapture::Status::recovering ||
        acquired == viewflow::reverse::d12::DesktopCapture::Status::busy) {
        std::printf("capture=pending-or-recovering transport_failure=0\n"); return 0;
    }
    if (acquired != viewflow::reverse::d12::DesktopCapture::Status::ready) return 1;
    auto texture = frame->texture11;
    auto imported = frame->texture12;
    const auto td = frame->description;
    std::printf("frame width=%u height=%u format=%u misc_flags=0x%x last_present_qpc=%lld accumulated_frames=%u\n",
        td.Width, td.Height, unsigned(td.Format), td.MiscFlags,
        static_cast<long long>(frame->info.LastPresentTime.QuadPart), frame->info.AccumulatedFrames);
    Producer producer; producer.device = d11; producer.context = c114; producer.source = texture;
    D3D11_TEXTURE2D_DESC sd = td;
    sd.Usage = D3D11_USAGE_STAGING; sd.BindFlags = 0; sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ; sd.MiscFlags = 0;
    hr = d11->CreateTexture2D(&sd, nullptr, producer.staging.GetAddressOf()); loghr("CreateTexture2D(reference staging)", hr); if (FAILED(hr)) return 1;
    hr = d115->CreateFence(0, D3D11_FENCE_FLAG_SHARED, IID_PPV_ARGS(producer.fence.GetAddressOf()));
    loghr("CreateFence(shared producer)", hr); if (FAILED(hr)) return 1;
    hr = producer.fence->CreateSharedHandle(nullptr, GENERIC_ALL, nullptr, &fence_handle.value);
    loghr("CreateSharedHandle(producer fence)", hr); if (FAILED(hr)) return 1;
    ComPtr<ID3D12Fence> imported_fence;
    hr = d12->OpenSharedHandle(fence_handle.value, IID_PPV_ARGS(imported_fence.GetAddressOf()));
    loghr("OpenSharedHandle(producer fence)", hr); if (FAILED(hr)) return 1;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp{}; UINT rows = 0; UINT64 row_bytes = 0, total = 0;
    const auto desc12 = imported->GetDesc();
    d12->GetCopyableFootprints(&desc12, 0, 1, 0, &fp, &rows, &row_bytes, &total);
    if (!total || total == UINT64_MAX || total > UINT64_MAX - 65535 || rows != td.Height || row_bytes != UINT64(td.Width) * 4) {
        std::printf("footprint=invalid\n"); return 1;
    }
    const UINT64 capacity = (total + 65535) & ~UINT64(65535);
    if (capacity > SIZE_MAX) return 1;
    pages->ptr = VirtualAlloc(nullptr, static_cast<SIZE_T>(capacity), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!pages->ptr) { std::printf("VirtualAlloc error=%lu\n", GetLastError()); return 1; }
    std::shared_ptr<viewflow::reverse::d12::ExternalHeap> heap;
    const char* diagnostic = nullptr;
    hr = viewflow::reverse::d12::ExternalHeap::open(d12.Get(), pages->ptr, capacity, pages, heap, diagnostic);
    loghr("ExternalHeap::open", hr); std::printf("heap diagnostic=%s\n", diagnostic); if (FAILED(hr)) return 1;
    D3D12_RESOURCE_DESC bd{}; bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width = total;
    bd.Alignment = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT; bd.Height = 1; bd.DepthOrArraySize = 1;
    bd.MipLevels = 1; bd.SampleDesc.Count = 1; bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    bd.Flags = D3D12_RESOURCE_FLAG_ALLOW_CROSS_ADAPTER;
    std::shared_ptr<viewflow::reverse::d12::ExternalBuffer> buffer;
    hr = viewflow::reverse::d12::ExternalBuffer::create(heap, 0, bd, D3D12_RESOURCE_STATE_COPY_DEST, buffer, diagnostic);
    loghr("ExternalBuffer::create", hr); std::printf("buffer diagnostic=%s\n", diagnostic); if (FAILED(hr)) return 1;
    // Declared after Producer, so its destructor drains D3D12 before D3D11/frame release.
    viewflow::reverse::d12::ExternalCopy copy;
    hr = copy.initialize(d12.Get()); loghr("ExternalCopy::initialize", hr); if (FAILED(hr)) return 1;
    producer.active = true;
    context->CopyResource(producer.staging.Get(), texture.Get());
    hr = c114->Signal(producer.fence.Get(), 1); producer.signaled = SUCCEEDED(hr); context->Flush();
    loghr("Signal(reference producer)", hr); if (FAILED(hr)) return 1;
    hr = copy.submit(imported.Get(), buffer, imported_fence.Get(), 1, frame);
    loghr("ExternalCopy::submit(actual DD frame direct)", hr);
    if (FAILED(hr) && !copy.in_flight()) return 1;
    viewflow::reverse::d12::ExternalCopy::Status status;
    do { status = copy.wait(100); }
    while (status == viewflow::reverse::d12::ExternalCopy::Status::pending);
    loghr("ExternalCopy::complete", copy.last_error());
    if (status != viewflow::reverse::d12::ExternalCopy::Status::complete || !producer.drain()) return 1;
    D3D11_MAPPED_SUBRESOURCE mapped{};
    hr = context->Map(producer.staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    loghr("Map(reference staging)", hr); if (FAILED(hr)) return 1;
    UINT64 mismatches = 0;
    if (mapped.RowPitch < row_bytes) { context->Unmap(producer.staging.Get(), 0); std::printf("reference_pitch=invalid\n"); return 1; }
    const auto* actual = static_cast<const volatile unsigned char*>(pages->ptr);
    const auto* reference = static_cast<const unsigned char*>(mapped.pData);
    for (UINT y = 0; y < td.Height; ++y)
        for (UINT64 x = 0; x < row_bytes; ++x)
            mismatches += actual[fp.Offset + UINT64(y) * fp.Footprint.RowPitch + x] != reference[SIZE_T(y) * mapped.RowPitch + x];
    context->Unmap(producer.staging.Get(), 0);
    const HRESULT end11 = d11->GetDeviceRemovedReason(), end12 = d12->GetDeviceRemovedReason();
    loghr("D3D11 GetDeviceRemovedReason", end11); loghr("D3D12 GetDeviceRemovedReason", end12);
    bool passed = !mismatches && SUCCEEDED(end11) && SUCCEEDED(end12);
    std::printf("direct_desktop_copy bytes=%llu mismatches=%llu result=%s scope=private-RAM-correctness ivshmem=untested performance=unmeasured\n",
        static_cast<unsigned long long>(row_bytes * td.Height), static_cast<unsigned long long>(mismatches), passed ? "passed" : "failed");
    // All GPU work is complete. COM source references are destroyed before the
    // acquired-frame RAII guard releases duplication ownership on function exit.
    producer.source.Reset(); texture.Reset(); imported.Reset();
    const HRESULT released = frame->release_after_gpu_completion();
    loghr("ReleaseFrame", released);
    return passed && SUCCEEDED(released) ? 0 : 1;
}
bool number(const char* s, UINT& n) {
    if (!s || *s < '0' || *s > '9') return false;
    char* end = nullptr; errno = 0; unsigned long v = std::strtoul(s, &end, 10);
    if (errno || *end || v > UINT_MAX) return false; n = static_cast<UINT>(v); return true;
}
}
int main(int argc, char** argv) {
    bool selected = false; UINT ai = 0, oi = 0; const char* path = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--capture-output") && !selected && i + 2 < argc) {
            if (!number(argv[i + 1], ai) || !number(argv[i + 2], oi)) return 2;
            selected = true; i += 2;
        } else if (!std::strcmp(argv[i], "--log") && !path && i + 1 < argc) path = argv[++i];
        else return 2;
    }
    if (!selected) { std::fprintf(stderr, "Usage: viewflow_d12_desktop_copy_probe --capture-output <adapter-index> <output-index> [--log <path>]\n"); return 2; }
    if (path) { FILE* file = nullptr; if (freopen_s(&file, path, "w", stdout)) return 1; }
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("scope=explicit-desktop-copy-private-RAM no_input=1 no_focus=1 no_pixel_dump=1 no_mode_change=1 fallback=none\n");
    return run(ai, oi);
}
