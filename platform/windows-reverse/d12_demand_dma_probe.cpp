// Explicit standalone scratch demand-DMA experiment. Never production banks.
// Host must have mapped the declared prefix through RDM before invocation.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winioctl.h>
#include <setupapi.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include <climits>
#include <cstring>
#include <vector>
#include <string>
#include "d12_external_heap.hpp"
#include "d12_external_copy.hpp"
#include "d12_shared_capture.hpp"
using Microsoft::WRL::ComPtr;
namespace {
constexpr UINT64 expected_bytes = UINT64(1073741824);
constexpr GUID interface_id = {0xdf576976,0x569d,0x4672,{0x95,0xa0,0xf5,0x7e,0x4e,0xa0,0xb2,0x10}};
struct DriverMap { UINT16 peer; UINT64 size; PVOID ptr; UINT16 vectors; };
static_assert(sizeof(void*) == 8 && sizeof(DriverMap) == 32);
void report(const char* stage, HRESULT hr) { std::printf("%s hr=0x%08lx\n", stage, static_cast<unsigned long>(hr)); }
bool restoration_failed = false;
struct Mapping {
    HANDLE handle = INVALID_HANDLE_VALUE;
    DriverMap map{};
    void* protected_tail = nullptr;
    SIZE_T protected_bytes = 0;
    DWORD old_protect = 0;
    ~Mapping() {
        if (protected_tail) {
            DWORD ignored = 0;
            const BOOL restored = VirtualProtect(protected_tail, protected_bytes, old_protect, &ignored);
            std::printf("tail protection restored=%u error=%lu\n", unsigned(restored), restored ? 0 : GetLastError());
            if (!restored) restoration_failed = true;
        }
        if (handle != INVALID_HANDLE_VALUE) { CloseHandle(handle); std::printf("bank mapping closed\n"); }
    }
    bool query(const char* stage, void* address, MEMORY_BASIC_INFORMATION& info) {
        const SIZE_T returned = VirtualQuery(address, &info, sizeof(info));
        std::printf("VirtualQuery stage=%s returned=%llu error=%lu AllocationBase=%p BaseAddress=%p RegionSize=%llu Protect=0x%lx\n",
            stage, static_cast<unsigned long long>(returned), returned ? 0 : GetLastError(), info.AllocationBase,
            info.BaseAddress, static_cast<unsigned long long>(info.RegionSize), info.Protect);
        return returned == sizeof(info);
    }
    bool protect_prefix(UINT64 prefix) {
        MEMORY_BASIC_INFORMATION first{}, tail{};
        auto* boundary = static_cast<unsigned char*>(map.ptr) + static_cast<SIZE_T>(prefix);
        const SIZE_T tail_bytes = static_cast<SIZE_T>(expected_bytes - prefix);
        if (!query("before-prefix", map.ptr, first) || !query("before-tail", boundary, tail)) return false;
        // One uniform original protection region permits exact restoration.
        const auto offset = reinterpret_cast<std::uintptr_t>(boundary) - reinterpret_cast<std::uintptr_t>(tail.BaseAddress);
        if (tail.AllocationBase != first.AllocationBase || offset > tail.RegionSize || tail_bytes > tail.RegionSize - offset) {
            std::printf("tail protection original-region unsupported; no fallback\n"); return false;
        }
        if (!VirtualProtect(boundary, tail_bytes, PAGE_NOACCESS, &old_protect)) {
            std::printf("VirtualProtect(tail PAGE_NOACCESS) failed error=%lu no_fallback=1\n", GetLastError()); return false;
        }
        protected_tail = boundary; protected_bytes = tail_bytes;
        std::printf("VirtualProtect(tail PAGE_NOACCESS) success offset=%llu bytes=%llu original=0x%lx\n",
            static_cast<unsigned long long>(prefix), static_cast<unsigned long long>(tail_bytes), old_protect);
        MEMORY_BASIC_INFORMATION after_prefix{}, after_tail{};
        return query("after-prefix", map.ptr, after_prefix) && query("after-tail", boundary, after_tail);
    }
    HRESULT open(DWORD requested_bus, DWORD requested_slot) {
        HDEVINFO info = SetupDiGetClassDevsW(&interface_id, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (info == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
        struct List { HDEVINFO info; ~List() { SetupDiDestroyDeviceInfoList(info); } } list{info};
        std::wstring path; unsigned matches = 0;
        for (DWORD i = 0;; ++i) {
            SP_DEVICE_INTERFACE_DATA iface{}; iface.cbSize = sizeof(iface);
            if (!SetupDiEnumDeviceInterfaces(info, nullptr, &interface_id, i, &iface)) {
                const DWORD error = GetLastError();
                if (error == ERROR_NO_MORE_ITEMS) break;
                return HRESULT_FROM_WIN32(error);
            }
            DWORD bytes = 0;
            SetupDiGetDeviceInterfaceDetailW(info, &iface, nullptr, 0, &bytes, nullptr);
            if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) return E_UNEXPECTED;
            std::vector<unsigned char> storage(bytes);
            auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
            detail->cbSize = sizeof(*detail);
            SP_DEVINFO_DATA device{}; device.cbSize = sizeof(device);
            if (!SetupDiGetDeviceInterfaceDetailW(info, &iface, detail, bytes, nullptr, &device)) return HRESULT_FROM_WIN32(GetLastError());
            DWORD bus = 0, address = 0, type = 0, returned = 0;
            if (!SetupDiGetDeviceRegistryPropertyW(info, &device, SPDRP_BUSNUMBER, &type,
                reinterpret_cast<BYTE*>(&bus), sizeof(bus), &returned)) return HRESULT_FROM_WIN32(GetLastError());
            if (type != REG_DWORD || returned != sizeof(bus)) return E_UNEXPECTED;
            if (!SetupDiGetDeviceRegistryPropertyW(info, &device, SPDRP_ADDRESS, &type,
                reinterpret_cast<BYTE*>(&address), sizeof(address), &returned)) return HRESULT_FROM_WIN32(GetLastError());
            if (type != REG_DWORD || returned != sizeof(address)) return E_UNEXPECTED;
            if (bus == requested_bus && address == (requested_slot << 16)) { ++matches; path = detail->DevicePath; }
        }
        std::printf("bank location bus=%lu slot=%lu function=0 matches=%u\n", requested_bus, requested_slot, matches);
        if (matches != 1) return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
        handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (handle == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
        unsigned char cache = 1; DWORD returned = 0;
        if (!DeviceIoControl(handle, CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS),
            &cache, sizeof(cache), &map, sizeof(map), &returned, nullptr)) return HRESULT_FROM_WIN32(GetLastError());
        std::printf("bank mapped bytes=%llu expected_bytes=%llu cache=1 returned=%lu\n",
            static_cast<unsigned long long>(map.size), static_cast<unsigned long long>(expected_bytes), returned);
        if (returned != sizeof(map) || !map.ptr || map.size != expected_bytes) return E_INVALIDARG;
        return S_OK;
    }
};
bool number(const char* text, UINT& value) {
    if (!text || *text < '0' || *text > '9') return false;
    char* end = nullptr; errno = 0; const unsigned long v = std::strtoul(text, &end, 10);
    if (errno || *end || v > UINT_MAX) return false;
    value = static_cast<UINT>(v); return true;
}
constexpr UINT64 image_bytes = UINT64(6144) * 3456 * 4;
bool copy6k(IDXGIAdapter1* adapter, ID3D12Device3* device,
            const std::shared_ptr<viewflow::reverse::d12::ExternalHeap>& heap,
            UINT64 mapped_prefix) {
    using namespace viewflow::reverse::d12;
    D3D12_RESOURCE_DESC buffer_desc{};
    buffer_desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    buffer_desc.Alignment = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;
    buffer_desc.Width = image_bytes; buffer_desc.Height = 1;
    buffer_desc.DepthOrArraySize = 1; buffer_desc.MipLevels = 1;
    buffer_desc.SampleDesc.Count = 1; buffer_desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    buffer_desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_CROSS_ADAPTER;
    const auto allocation = device->GetResourceAllocationInfo(0, 1, &buffer_desc);
    if (!allocation.SizeInBytes || allocation.SizeInBytes > mapped_prefix) {
        std::printf("resource allocation exceeds host-mapped prefix\n"); return false;
    }
    std::shared_ptr<ExternalBuffer> destination;
    const char* diagnostic = nullptr;
    HRESULT hr = ExternalBuffer::create(heap, 0, buffer_desc, D3D12_RESOURCE_STATE_COPY_DEST, destination, diagnostic);
    report("ExternalBuffer::create(prefix only)", hr);
    std::printf("resource diagnostic=%s allocation_bytes=%llu\n", diagnostic,
                static_cast<unsigned long long>(allocation.SizeInBytes));
    if (FAILED(hr)) return false;
    ComPtr<ID3D11Device> d11; ComPtr<ID3D11DeviceContext> context;
    hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, d11.GetAddressOf(), nullptr, context.GetAddressOf());
    report("D3D11CreateDevice(pattern source)", hr); if (FAILED(hr)) return false;
    // Source-only CPU allocation. The destination BAR is never read, filled,
    // mapped as a resource, or compared by the CPU in this probe.
    std::vector<unsigned char> pattern(static_cast<SIZE_T>(image_bytes));
    for (SIZE_T i = 0; i < pattern.size(); ++i)
        pattern[i] = static_cast<unsigned char>((i * 37 + (i >> 8) + 91) & 255);
    D3D11_TEXTURE2D_DESC td{};
    td.Width = 6144; td.Height = 3456; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA data{}; data.pSysMem = pattern.data(); data.SysMemPitch = 6144 * 4;
    ComPtr<ID3D11Texture2D> source;
    hr = d11->CreateTexture2D(&td, &data, source.GetAddressOf());
    report("CreateTexture2D(6K DEFAULT BGRA known pattern)", hr); if (FAILED(hr)) return false;
    SharedCapture bridge;
    hr = bridge.initialize(d11.Get(), context.Get(), device);
    report("SharedCapture::initialize", hr); if (FAILED(hr)) return false;
    std::shared_ptr<SharedCapture::Snapshot> snapshot;
    if (bridge.capture(source.Get(), snapshot) != SharedCapture::Status::ready) {
        report("SharedCapture::capture", bridge.last_error());
        std::printf("capture diagnostic=%s\n", bridge.diagnostic()); return false;
    }
    ExternalCopy copy;
    hr = copy.initialize(device); report("ExternalCopy::initialize", hr); if (FAILED(hr)) return false;
    hr = copy.submit(snapshot->resource.Get(), destination, snapshot->fence.Get(), snapshot->value, snapshot);
    report("ExternalCopy::submit(prefix)", hr);
    const bool submission_failed = FAILED(hr);
    if (submission_failed && !copy.in_flight()) return false;
    ExternalCopy::Status state;
    do { state = copy.wait(100); } while (state == ExternalCopy::Status::pending);
    report("ExternalCopy::completion", copy.last_error());
    if (state != ExternalCopy::Status::complete || submission_failed) return false;
    hr = d11->GetDeviceRemovedReason(); report("D3D11 GetDeviceRemovedReason", hr); if (FAILED(hr)) return false;
    std::printf("GPU copy completed offset=0 bytes=84934656 width=6144 height=3456 row_pitch=24576 "
                "pattern=(i*37+(i>>8)+91)&255 destination_CPU_access=none host_verification=required\n");
    return true;
}
int run(UINT bus, UINT slot, UINT adapter_index, UINT64 mapped_prefix, bool do_copy, bool map_only, bool prefix_only) {
    // The shared owner survives device/heap import and closes only after release.
    auto mapping = std::make_shared<Mapping>();
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()));
    report("CreateDXGIFactory1", hr); if (FAILED(hr)) return 1;
    ComPtr<IDXGIAdapter1> adapter;
    hr = factory->EnumAdapters1(adapter_index, adapter.GetAddressOf());
    report("EnumAdapters1(explicit)", hr); if (FAILED(hr)) return 1;
    DXGI_ADAPTER_DESC1 desc{};
    hr = adapter->GetDesc1(&desc); report("GetDesc1", hr); if (FAILED(hr)) return 1;
    if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) { std::printf("software adapter rejected\n"); return 1; }
    char name[512]{}; WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof(name), nullptr, nullptr);
    std::printf("adapter index=%u name=%s luid=%08lx:%08lx\n", adapter_index, name,
        static_cast<unsigned long>(desc.AdapterLuid.HighPart), static_cast<unsigned long>(desc.AdapterLuid.LowPart));
    ComPtr<ID3D12Device3> device;
    hr = D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(device.GetAddressOf()));
    report("D3D12CreateDevice(Device3)", hr); if (FAILED(hr)) return 1;
    hr = mapping->open(bus, slot); report("bank map exact location/extent", hr); if (FAILED(hr)) return 1;
    if (prefix_only && !mapping->protect_prefix(mapped_prefix)) return 1;
    if (map_only) {
        std::printf("bank mapped mode=map-only hold_ms=20000 no_heap_import=1 no_gpu_commands=1 destination_CPU_access=none\n");
        std::fflush(stdout);
        Sleep(20000);
        hr = device->GetDeviceRemovedReason(); report("GetDeviceRemovedReason(after map hold)", hr);
        device.Reset(); mapping.reset();
        std::printf("probe complete mode=map-only residency=requires-host-observation\n");
        return SUCCEEDED(hr) ? 0 : 1;
    }
    std::shared_ptr<viewflow::reverse::d12::ExternalHeap> heap;
    const char* diagnostic = nullptr;
    hr = viewflow::reverse::d12::ExternalHeap::open(device.Get(), mapping->map.ptr, expected_bytes, mapping, heap, diagnostic);
    report("ExternalHeap::open(import only)", hr); std::printf("diagnostic=%s\n", diagnostic);
    if (FAILED(hr)) { report("GetDeviceRemovedReason(import failure)", device->GetDeviceRemovedReason()); return 1; }
    if (prefix_only && heap->description().SizeInBytes > mapped_prefix) {
        std::printf("prefix import rejected heap_bytes=%llu declared_prefix=%llu no_resources_or_GPU_commands=1\n",
            static_cast<unsigned long long>(heap->description().SizeInBytes), static_cast<unsigned long long>(mapped_prefix));
        return 1;
    }
    std::printf("heap imported mode=%s hold_ms=%u bytes=%llu heap_bytes=%llu destination_CPU_access=none\n",
        prefix_only ? (do_copy ? "prefix-6k-copy" : "prefix-import-only") : (do_copy ? "6k-copy" : "import-only"), do_copy ? 0u : 20000u,
        static_cast<unsigned long long>(expected_bytes), static_cast<unsigned long long>(heap->description().SizeInBytes));
    std::fflush(stdout);
    const bool copied = !do_copy || copy6k(adapter.Get(), device.Get(), heap, mapped_prefix);
    if (!do_copy) Sleep(20000);
    hr = device->GetDeviceRemovedReason(); report("GetDeviceRemovedReason(after hold)", hr);
    heap.reset(); std::printf("heap released\n");
    device.Reset();
    mapping.reset();
    std::printf("probe complete residency=requires-host-observation transport=untested\n");
    return copied && SUCCEEDED(hr) ? 0 : 1;
}
}
int main(int argc, char** argv) {
    UINT bus = 0, slot = 0, adapter = 0, capacity = 0, prefix = 0;
    const bool mode_valid = argc == 8 && (!std::strcmp(argv[7], "map-only") || !std::strcmp(argv[7], "import-only") || !std::strcmp(argv[7], "6k-copy") || !std::strcmp(argv[7], "prefix-import-only") || !std::strcmp(argv[7], "prefix-6k-copy"));
    if (!mode_valid || std::strcmp(argv[1], "--scratch") || !number(argv[2], bus) || bus > 255 ||
        !number(argv[3], slot) || slot > 31 || (slot >= 5 && slot <= 9) || !number(argv[4], adapter) ||
        !number(argv[5], capacity) || capacity != expected_bytes || !number(argv[6], prefix) ||
        (prefix != 1048576 && prefix != image_bytes) ||
        ((!std::strcmp(argv[7], "6k-copy") || !std::strcmp(argv[7], "prefix-6k-copy")) && prefix < image_bytes) ||
        ((!std::strcmp(argv[7], "prefix-import-only") || !std::strcmp(argv[7], "prefix-6k-copy")) && slot < 10)) {
        std::fprintf(stderr, "Usage: viewflow_d12_demand_dma_probe --scratch <bus> <slot> <adapter-index> 1073741824 <1048576|84934656> <map-only|import-only|6k-copy|prefix-import-only|prefix-6k-copy>\n"
                            "Slots 5..9 are production and always rejected. No implicit/default capture or import.\n");
        return 2;
    }
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("PRECONDITION: host RDM must already map the declared scratch prefix for this exact device; "
                "CLI is an operator assertion, not automatic host verification. Production banks forbidden.\n");
    std::printf("scope=scratch-demand-DMA adapter=%u bus=%u slot=%u capacity=%u mapped_prefix=%u cache=1 "
                "mode=%s destination_CPU_access=none production=forbidden\n", adapter, bus, slot, capacity, prefix, argv[7]);
    try {
        const bool prefix_mode = !std::strcmp(argv[7], "prefix-import-only") || !std::strcmp(argv[7], "prefix-6k-copy");
        const int status = run(bus, slot, adapter, prefix,
            !std::strcmp(argv[7], "6k-copy") || !std::strcmp(argv[7], "prefix-6k-copy"),
            !std::strcmp(argv[7], "map-only"), prefix_mode);
        return restoration_failed ? 1 : status;
    }
    catch (const std::bad_alloc&) { report("probe allocation", E_OUTOFMEMORY); return 1; }
    catch (const std::exception& e) { std::fprintf(stderr, "probe failed: %s\n", e.what()); return 1; }
}
