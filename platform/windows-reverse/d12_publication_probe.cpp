#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11_4.h>
#include <dxgi1_2.h>
#include <cstdio>
#include <cstring>
#include <vector>
#include "d12_publication.hpp"
#include "d12_shared_capture.hpp"
using Microsoft::WRL::ComPtr;
namespace {
struct Memory {
    void* control = nullptr;
    std::array<void*, viewflow::reverse::shm::slots> banks{};
    ~Memory() { for (auto p : banks) if (p) VirtualFree(p, 0, MEM_RELEASE); if (control) VirtualFree(control, 0, MEM_RELEASE); }
};
void result(const char* text, HRESULT hr) { std::printf("%s hr=0x%08lx\n", text, static_cast<unsigned long>(hr)); }
int run(IDXGIAdapter1* adapter, UINT width, UINT height) {
    using namespace viewflow::reverse;
    ComPtr<ID3D11Device> d11; ComPtr<ID3D11DeviceContext> context;
    HRESULT hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, d11.GetAddressOf(), nullptr, context.GetAddressOf());
    result("D3D11CreateDevice", hr); if (FAILED(hr)) return 1;
    ComPtr<ID3D12Device3> d12;
    hr = D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(d12.GetAddressOf()));
    result("D3D12CreateDevice", hr); if (FAILED(hr)) return 1;
    const SIZE_T image_bytes = SIZE_T(width) * height * 4;
    const SIZE_T capacity = (image_bytes + 65535) & ~SIZE_T(65535);
    auto memory = std::make_shared<Memory>();
    memory->control = VirtualAlloc(nullptr, shm::header_bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!memory->control) return 1;
    for (auto& p : memory->banks) { p = VirtualAlloc(nullptr, capacity, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE); if (!p) return 1; }
    auto frames = std::make_shared<shm::Frames>(memory->control, shm::header_bytes, memory->banks, capacity);
    d12::PendingPublication::Banks banks{};
    unsigned bank_requests=0;
    const auto bank_for_slot=[&](unsigned i) {
        ++bank_requests;
        if(banks[i])return banks[i];
        const char* diag = nullptr;
        const auto imported = d12::ExternalHeap::open(d12.Get(), memory->banks[i], capacity, memory, banks[i], diag);
        result("ExternalHeap::open(selected private bank)", imported);
        if (FAILED(imported))std::printf("diagnostic=%s\n",diag);
        return banks[i];
    };
    std::vector<unsigned char> pattern(image_bytes);
    for (SIZE_T i = 0; i < image_bytes; ++i) pattern[i] = static_cast<unsigned char>((i * 37 + (i >> 8) + 91) & 255);
    D3D11_TEXTURE2D_DESC td{};
    td.Width = width; td.Height = height; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA data{}; data.pSysMem = pattern.data(); data.SysMemPitch = width * 4;
    ComPtr<ID3D11Texture2D> source;
    hr = d11->CreateTexture2D(&td, &data, source.GetAddressOf()); result("CreateTexture2D(pattern)", hr); if (FAILED(hr)) return 1;
    d12::SharedCapture bridge;
    hr = bridge.initialize(d11.Get(), context.Get(), d12.Get()); result("SharedCapture::initialize", hr); if (FAILED(hr)) return 1;
    std::shared_ptr<d12::SharedCapture::Snapshot> snapshot;
    if (bridge.capture(source.Get(), snapshot) != d12::SharedCapture::Status::ready) {
        result("SharedCapture::capture", bridge.last_error()); return 1;
    }
    d12::PendingPublication publication(frames, memory);
    hr = publication.initialize(d12.Get()); result("PendingPublication::initialize", hr); if (FAILED(hr)) return 1;
    hr = publication.begin_with_bank(snapshot->resource.Get(), bank_for_slot, 1, 1, snapshot, snapshot->fence.Get(), snapshot->value);
    result("PendingPublication::begin", hr);
    if (FAILED(hr) && !publication.active()) return 1;
    auto* slots = static_cast<shm::Slot*>(memory->control);
    const auto before = std::atomic_ref(slots[0].state).load(std::memory_order_acquire);
    std::printf("before_poll slot0_state=%llu expected_writing=1\n", static_cast<unsigned long long>(before));
    if (before != 1) return 1;
    std::vector<std::uint8_t> reference;
    d12::PendingPublication::Status status;
    do { status = publication.poll(reference, 100); } while (status == d12::PendingPublication::Status::pending);
    result("PendingPublication::poll", publication.last_error());
    if (status != d12::PendingPublication::Status::published) { std::printf("diagnostic=%s\n", publication.diagnostic()); return 1; }
    auto read = frames->acquire(reference, width, height, memory);
    if (!read) return 1;
    SIZE_T mismatch = 0;
    for (SIZE_T i = 0; i < image_bytes; ++i) mismatch += read->bytes[i] != pattern[i];
    std::printf("publication_pixels bytes=%llu mismatches=%llu\n", static_cast<unsigned long long>(image_bytes), static_cast<unsigned long long>(mismatch));
    read.reset(); reference.clear();
    hr = publication.begin_with_bank(snapshot->resource.Get(), bank_for_slot, 1, 2, snapshot, snapshot->fence.Get(), snapshot->value);
    result("PendingPublication::begin(cancel)", hr); if (FAILED(hr) && !publication.active()) return 1;
    const auto during = std::atomic_ref(slots[1].state).load(std::memory_order_acquire);
    publication.cancel(); // Drains GPU work before releasing the write slot.
    const auto after = std::atomic_ref(slots[1].state).load(std::memory_order_acquire);
    const HRESULT end11=d11->GetDeviceRemovedReason(),end12=d12->GetDeviceRemovedReason();
    result("D3D11 GetDeviceRemovedReason",end11);result("D3D12 GetDeviceRemovedReason",end12);
    const bool lazy=bank_requests==2 && banks[0] && banks[1] && !banks[2] && !banks[3];
    std::printf("bank_imports requested=%u untouched_banks_unimported=%u\n",bank_requests,unsigned(lazy));
    const bool passed = !mismatch && during == 1 && after == 0 && !publication.active() && SUCCEEDED(end11) && SUCCEEDED(end12) && lazy;
    std::printf("cancel slot1_before=%llu slot1_after=%llu result=%s scope=synthetic-privatebanks-not-IVSHMEM\n",
        static_cast<unsigned long long>(during), static_cast<unsigned long long>(after), passed ? "passed" : "failed");
    return passed ? 0 : 1;
}
}
int main(int argc, char** argv) {
    const bool sixk = argc == 2 && !std::strcmp(argv[1], "--6k");
    if (argc != 1 && !sixk) return 2;
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf())); result("CreateDXGIFactory1", hr); if (FAILED(hr)) return 1;
    for (UINT i = 0;; ++i) {
        ComPtr<IDXGIAdapter1> adapter; hr = factory->EnumAdapters1(i, adapter.GetAddressOf());
        if (hr == DXGI_ERROR_NOT_FOUND) return 1;
        if (FAILED(hr)) return 1;
        DXGI_ADAPTER_DESC1 desc{}; hr = adapter->GetDesc1(&desc); if (FAILED(hr)) return 1;
        if (!(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) return run(adapter.Get(), sixk ? 6144 : 64, sixk ? 3456 : 64);
    }
}
