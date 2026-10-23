// Synthetic D3D11 -> D3D12 -> external private RAM correctness probe.
// No desktop capture, IVSHMEM mapping, input or performance measurements.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdint>
#include <vector>
#include <memory>
#include "d12_external_heap.hpp"
#include "d12_external_copy.hpp"
#include "d12_shared_capture.hpp"
using Microsoft::WRL::ComPtr;
namespace {
constexpr UINT width = 6144, height = 3456, pitch = width * 4;
constexpr SIZE_T bytes = SIZE_T(pitch) * height;
void report(const char* stage, HRESULT hr) {
    std::printf("%s hr=0x%08lx\n", stage, static_cast<unsigned long>(hr));
}
struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value) CloseHandle(value); }
};
struct Pages {
    void* ptr = VirtualAlloc(nullptr, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    ~Pages() { if (ptr) VirtualFree(ptr, 0, MEM_RELEASE); }
};
unsigned char pattern(SIZE_T i) {
    const SIZE_T pixel = i / 4, x = pixel % width, y = pixel / width, c = i % 4;
    return static_cast<unsigned char>((x * 17 + y * 29 + c * 61 + (x >> 8) + (y >> 8)) & 255);
}

// Independent producer lifetime guard covers every early return after the
// D3D11 upload. Normal flow does not CPU-wait before ExternalCopy submits its
// GPU-side dependency; cleanup drains only if the consumer has not already done so.
struct ProducerDrain {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext4> context;
    ComPtr<ID3D11Fence> fence;
    ComPtr<ID3D11Texture2D> texture;
    bool active = false, signaled = false;
    ~ProducerDrain() {
        if (!active) return;
        while (SUCCEEDED(device->GetDeviceRemovedReason())) {
            if (signaled) {
                const UINT64 completed = fence->GetCompletedValue();
                if (completed >= 1) return; // UINT64_MAX also means device removal.
            } else {
                signaled = SUCCEEDED(context->Signal(fence.Get(), 1));
                context->Flush();
            }
            Sleep(1);
        }
    }
};

bool inspect(IDXGIAdapter1* adapter) {
    // Owners/handles declared first: outlive all subsequently created GPU objects.
    auto pages = std::make_shared<Pages>();
    if (!pages->ptr) { std::printf("VirtualAlloc error=%lu\n", GetLastError()); return false; }
    Handle texture_handle, fence_handle;
    ComPtr<ID3D11Device> device11;
    ComPtr<ID3D11DeviceContext> context11;
    D3D_FEATURE_LEVEL chosen{};
    HRESULT hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
        device11.GetAddressOf(), &chosen, context11.GetAddressOf());
    report("D3D11CreateDevice", hr); if (FAILED(hr)) return false;
    ComPtr<ID3D11Device5> device115;
    ComPtr<ID3D11DeviceContext4> context114;
    hr = device11.As(&device115); report("QueryInterface(Device5)", hr); if (FAILED(hr)) return false;
    hr = context11.As(&context114); report("QueryInterface(Context4)", hr); if (FAILED(hr)) return false;
    ComPtr<ID3D12Device3> device12;
    hr = D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(device12.GetAddressOf()));
    report("D3D12CreateDevice(Device3)", hr); if (FAILED(hr)) return false;
    D3D11_TEXTURE2D_DESC td{};
    td.Width = width; td.Height = height; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> ordinary;
    hr = device11->CreateTexture2D(&td, nullptr, ordinary.GetAddressOf());
    report("CreateTexture2D(ordinary non-shared source)", hr); if (FAILED(hr)) return false;
    viewflow::reverse::d12::SharedCapture bridge;
    hr = bridge.initialize(device11.Get(), context11.Get(), device12.Get());
    report("SharedCapture::initialize", hr); if (FAILED(hr)) return false;
    std::shared_ptr<viewflow::reverse::d12::ExternalHeap> heap;
    const char* diagnostic = nullptr;
    hr = viewflow::reverse::d12::ExternalHeap::open(device12.Get(), pages->ptr, bytes, pages, heap, diagnostic);
    report("ExternalHeap::open(private)", hr); if (FAILED(hr)) return false;
    D3D12_RESOURCE_DESC bd{};
    bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Alignment = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;
    bd.Width = bytes; bd.Height = 1; bd.DepthOrArraySize = 1; bd.MipLevels = 1;
    bd.SampleDesc.Count = 1; bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    bd.Flags = D3D12_RESOURCE_FLAG_ALLOW_CROSS_ADAPTER;
    std::shared_ptr<viewflow::reverse::d12::ExternalBuffer> buffer;
    hr = viewflow::reverse::d12::ExternalBuffer::create(heap, 0, bd, D3D12_RESOURCE_STATE_COPY_DEST, buffer, diagnostic);
    report("ExternalBuffer::create", hr); if (FAILED(hr)) return false;
    viewflow::reverse::d12::ExternalCopy copy;
    hr = copy.initialize(device12.Get()); report("ExternalCopy::initialize", hr); if (FAILED(hr)) return false;
    std::vector<unsigned char> source(bytes);
    // Hold frame zero across frame one's capture to prove an outstanding snapshot
    // is not overwritten. Frame two drops both, exercising reusable pool storage.
    std::shared_ptr<viewflow::reverse::d12::SharedCapture::Snapshot> retained;
    for (unsigned frame = 0; frame < 3; ++frame) {
        if (frame == 2) retained.reset();
        for (SIZE_T i = 0; i < bytes; ++i) source[i] = static_cast<unsigned char>(pattern(i) + frame * 53);
        ComPtr<ID3D11Fence> guard_fence;
        hr = device115->CreateFence(0, D3D11_FENCE_FLAG_NONE, IID_PPV_ARGS(guard_fence.GetAddressOf()));
        report("CreateFence(source producer guard)", hr); if (FAILED(hr)) return false;
        ProducerDrain producer{device11, context114, guard_fence, ordinary};
        producer.active = true;
        context11->UpdateSubresource(ordinary.Get(), 0, nullptr, source.data(), pitch, 0);
        hr = context114->Signal(guard_fence.Get(), 1);
        producer.signaled = SUCCEEDED(hr); context11->Flush();
        report("Signal(source upload guard)", hr); if (FAILED(hr)) return false;
        std::shared_ptr<viewflow::reverse::d12::SharedCapture::Snapshot> snapshot;
        const auto captured = bridge.capture(ordinary.Get(), snapshot);
        report("SharedCapture::capture", bridge.last_error());
        std::printf("shared_capture frame=%u diagnostic=%s\n", frame, bridge.diagnostic());
        if (captured != viewflow::reverse::d12::SharedCapture::Status::ready) return false;
        if (retained && retained.get() == snapshot.get()) {
            std::printf("retained_snapshot_reused=1 result=failed\n"); return false;
        }
        hr = copy.submit(snapshot->resource.Get(), buffer, snapshot->fence.Get(), snapshot->value, snapshot);
        report("ExternalCopy::submit(owned capture)", hr);
        if (FAILED(hr) && !copy.in_flight()) return false;
        std::weak_ptr<viewflow::reverse::d12::SharedCapture::Snapshot> lease = snapshot;
        snapshot.reset();
        // Pool + submitted copy must hold the snapshot even after the caller
        // drops its reference. COM texture ownership alone cannot prevent reuse.
        if (lease.use_count() != 2) {
            std::printf("source_lease retained_by_copy=0 result=failed\n"); return false;
        }
        viewflow::reverse::d12::ExternalCopy::Status status;
        do { status = copy.wait(100); }
        while (status == viewflow::reverse::d12::ExternalCopy::Status::pending);
        report("ExternalCopy::complete", copy.last_error());
        if (status != viewflow::reverse::d12::ExternalCopy::Status::complete) return false;
        if (lease.use_count() != 1) {
            std::printf("source_lease released_after_copy=0 result=failed\n"); return false;
        }
        std::printf("source_lease retained_by_copy=1 released_after_copy=1\n");
        const auto* output = static_cast<const volatile unsigned char*>(pages->ptr);
        SIZE_T mismatches = 0, first = bytes;
        for (SIZE_T i = 0; i < bytes; ++i) if (output[i] != source[i]) { if (!mismatches) first = i; ++mismatches; }
        std::printf("d3d11_d3d12_external_private_copy frame=%u width=%u height=%u bytes=%llu mismatches=%llu first_mismatch=%llu result=%s\n",
            frame, width, height, static_cast<unsigned long long>(bytes), static_cast<unsigned long long>(mismatches),
            static_cast<unsigned long long>(first), mismatches ? "failed" : "passed");
        if (mismatches) return false;
        if (frame == 0) retained = lease.lock();
    }
    const HRESULT final11 = device11->GetDeviceRemovedReason();
    const HRESULT final12 = device12->GetDeviceRemovedReason();
    report("D3D11 GetDeviceRemovedReason", final11);
    report("D3D12 GetDeviceRemovedReason", final12);
    return SUCCEEDED(final11) && SUCCEEDED(final12);
}
}
int main(int argc, char**) {
    if (argc != 1) { std::fprintf(stderr, "Usage: viewflow_d12_shared_texture_probe\n"); return 2; }
    std::printf("scope=synthetic-private-6K-correctness no_capture=1 no_ivshmem=1 no_input=1\n");
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()));
    report("CreateDXGIFactory1", hr); if (FAILED(hr)) return 1;
    unsigned adapters = 0, passed = 0;
    for (UINT i = 0;; ++i) {
        ComPtr<IDXGIAdapter1> adapter;
        hr = factory->EnumAdapters1(i, adapter.GetAddressOf());
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr)) { report("EnumAdapters1", hr); return 1; }
        DXGI_ADAPTER_DESC1 desc{};
        hr = adapter->GetDesc1(&desc); report("GetDesc1", hr); if (FAILED(hr)) return 1;
        if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
        ++adapters;
        char name[512]{};
        WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof(name), nullptr, nullptr);
        std::printf("adapter=%u name=\"%s\" vendor=0x%x device=0x%x\n", i, name, desc.VendorId, desc.DeviceId);
        if (inspect(adapter.Get())) ++passed;
    }
    std::printf("hardware_adapters=%u passed=%u actual_WGC_shareability=untested production_transport=untested\n", adapters, passed);
    return adapters && passed == adapters ? 0 : 1;
}
