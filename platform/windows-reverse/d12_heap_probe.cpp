// Standalone D3D12 external-heap probe. IVSHMEM scratch and GPU copy are explicit opt-ins.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <winioctl.h>
#include <setupapi.h>
#include <vector>
#include <string>
#include <cstdlib>
#include <cerrno>
#include "d12_external_heap.hpp"
#include "d12_external_copy.hpp"

using Microsoft::WRL::ComPtr;

namespace {
void result(const char* operation, HRESULT hr) {
    std::printf("%s hr=0x%08lx\n", operation, static_cast<unsigned long>(hr));
}

// Declared before the device below: reverse destruction releases the resource,
// heap and device before freeing this allocation, including every failure path.
struct PrivatePages {
    void* base = nullptr;
    ~PrivatePages() {
        if (base && !VirtualFree(base, 0, MEM_RELEASE))
            std::printf("VirtualFree error=%lu\n", GetLastError());
    }
    PrivatePages() = default;
    PrivatePages(const PrivatePages&) = delete;
    PrivatePages& operator=(const PrivatePages&) = delete;
};

constexpr UINT64 scratch_bytes = 16 * 1024 * 1024;
constexpr GUID ivshmem_interface = {0xdf576976,0x569d,0x4672,{0x95,0xa0,0xf5,0x7e,0x4e,0xa0,0xb2,0x10}};
struct DriverMap { UINT16 peer; UINT64 size; PVOID ptr; UINT16 vectors; };
static_assert(sizeof(void*) == 8 && sizeof(DriverMap) == 32);
struct ScratchMapping {
    HANDLE handle = INVALID_HANDLE_VALUE;
    DriverMap map{};
    ~ScratchMapping() { if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle); }
    bool open(DWORD requested_bus, DWORD requested_slot, unsigned char cache) {
        const auto info = SetupDiGetClassDevsW(&ivshmem_interface, nullptr, nullptr,
                                               DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (info == INVALID_HANDLE_VALUE) return false;
        struct List { HDEVINFO info; ~List() { SetupDiDestroyDeviceInfoList(info); } } guard{info};
        std::wstring path;
        unsigned matches = 0;
        for (DWORD i = 0;; ++i) {
            SP_DEVICE_INTERFACE_DATA iface{}; iface.cbSize = sizeof(iface);
            if (!SetupDiEnumDeviceInterfaces(info, nullptr, &ivshmem_interface, i, &iface)) {
                if (GetLastError() == ERROR_NO_MORE_ITEMS) break;
                return false;
            }
            DWORD bytes = 0;
            SetupDiGetDeviceInterfaceDetailW(info, &iface, nullptr, 0, &bytes, nullptr);
            if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) return false;
            std::vector<unsigned char> storage(bytes);
            auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
            detail->cbSize = sizeof(*detail);
            SP_DEVINFO_DATA dev{}; dev.cbSize = sizeof(dev);
            if (!SetupDiGetDeviceInterfaceDetailW(info, &iface, detail, bytes, nullptr, &dev)) return false;
            DWORD bus = 0, address = 0, type = 0, returned = 0;
            if (!SetupDiGetDeviceRegistryPropertyW(info, &dev, SPDRP_BUSNUMBER, &type,
                reinterpret_cast<BYTE*>(&bus), sizeof(bus), &returned) ||
                type != REG_DWORD || returned != sizeof(bus)) return false;
            if (!SetupDiGetDeviceRegistryPropertyW(info, &dev, SPDRP_ADDRESS, &type,
                reinterpret_cast<BYTE*>(&address), sizeof(address), &returned) ||
                type != REG_DWORD || returned != sizeof(address)) return false;
            // PCI SPDRP_ADDRESS: high WORD=device, low WORD=function.
            if (bus == requested_bus && address == (requested_slot << 16)) {
                path = detail->DevicePath;
                ++matches;
            }
        }
        if (matches != 1) {
            std::printf("scratch_location matches=%u expected=1\n", matches);
            return false;
        }
        handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                             nullptr, OPEN_EXISTING, 0, nullptr);
        if (handle == INVALID_HANDLE_VALUE) return false;
        DWORD returned = 0;
        if (!DeviceIoControl(handle, CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802,
                METHOD_BUFFERED, FILE_ANY_ACCESS), &cache, sizeof(cache),
                &map, sizeof(map), &returned, nullptr)) return false;
        if (returned != sizeof(map) || !map.ptr || map.size != scratch_bytes) {
            std::printf("scratch_map rejected bytes=%llu expected=%llu returned=%lu\n",
                static_cast<unsigned long long>(map.size),
                static_cast<unsigned long long>(scratch_bytes), returned);
            return false;
        }
        std::printf("scratch_map bus=%lu slot=%lu function=0 bytes=%llu cache=%u\n",
            requested_bus, requested_slot, static_cast<unsigned long long>(map.size), unsigned(cache));
        return true;
    }
};
bool number(const char* text, UINT64& value) {
    if (!text || !*text || *text == '-' || *text == '+') return false;
    char* end = nullptr;
    errno = 0;
    value = std::strtoull(text, &end, 0);
    return !errno && end != text && !*end;
}

// The caller owns the imported memory until this function drains its queue.
void copy_private(ID3D12Device* device, std::shared_ptr<viewflow::reverse::d12::ExternalBuffer> destination_owner, void* cpu, bool scratch, bool test_texture = false) {
    ID3D12Resource* destination = destination_owner->get();
    const UINT64 bytes = test_texture ? UINT64(6144) * 3456 * 4 : 1024 * 1024;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> list;
    ComPtr<ID3D12Fence> fence;
    ComPtr<ID3D12Resource> upload;
    ComPtr<ID3D12Resource> texture;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    if (test_texture) {
        D3D12_RESOURCE_DESC td{};
        td.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        td.Width = 6144; td.Height = 3456;
        td.DepthOrArraySize = 1; td.MipLevels = 1;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.SampleDesc.Count = 1;
        UINT rows = 0; UINT64 row_bytes = 0, required = 0;
        device->GetCopyableFootprints(&td, 0, 1, 0, &footprint, &rows, &row_bytes, &required);
        // This mode verifies every byte in a tight 6K BGRA image. Reject an
        // unexpected footprint rather than silently skipping padding or rows.
        if (required != bytes || rows != 3456 || row_bytes != 6144 * 4 ||
            footprint.Offset != 0 || footprint.Footprint.RowPitch != 6144 * 4 ||
            destination->GetDesc().Width < required) {
            std::printf("private_texture footprint=unexpected; no commands submitted\n");
            return;
        }
        D3D12_HEAP_PROPERTIES hp{}; hp.Type = D3D12_HEAP_TYPE_DEFAULT;
        const HRESULT create_hr = device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE,
            &td, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(texture.GetAddressOf()));
        result("CreateCommittedResource(DEFAULT,6K-BGRA8-texture)", create_hr);
        if (FAILED(create_hr)) return;
    }
    D3D12_COMMAND_QUEUE_DESC q{};
    q.Type = D3D12_COMMAND_LIST_TYPE_COPY;
    HRESULT hr = device->CreateCommandQueue(&q, IID_PPV_ARGS(queue.GetAddressOf()));
    result("CreateCommandQueue(COPY)", hr);
    if (FAILED(hr)) return;
    hr = device->CreateCommandAllocator(q.Type, IID_PPV_ARGS(allocator.GetAddressOf()));
    result("CreateCommandAllocator", hr);
    if (FAILED(hr)) return;
    hr = device->CreateCommandList(0, q.Type, allocator.Get(), nullptr,
                                   IID_PPV_ARGS(list.GetAddressOf()));
    result("CreateCommandList", hr);
    if (FAILED(hr)) return;
    hr = device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(fence.GetAddressOf()));
    result("CreateFence", hr);
    if (FAILED(hr)) return;
    D3D12_HEAP_PROPERTIES props{};
    props.Type = D3D12_HEAP_TYPE_UPLOAD;
    D3D12_RESOURCE_DESC desc = destination->GetDesc();
    desc.Flags = D3D12_RESOURCE_FLAG_NONE;
    hr = device->CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc,
        D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(upload.GetAddressOf()));
    result("CreateCommittedResource(upload)", hr);
    if (FAILED(hr)) return;
    void* mapped = nullptr;
    D3D12_RANGE no_read{0, 0};
    hr = upload->Map(0, &no_read, &mapped);
    result("Map(upload)", hr);
    if (FAILED(hr)) return;
    const auto pattern = [test_texture](UINT64 i) {
        if (!test_texture) return static_cast<unsigned char>((i * 37 + (i >> 8) + 91) & 255);
        const UINT64 pixel = i / 4, x = pixel % 6144, y = pixel / 6144, channel = i % 4;
        return static_cast<unsigned char>((x * 17 + y * 29 + channel * 61 + (x >> 8) + (y >> 8)) & 255);
    };
    for (UINT64 i = 0; i < bytes; ++i)
        static_cast<unsigned char*>(mapped)[i] = pattern(i);
    D3D12_RANGE written{0, static_cast<SIZE_T>(bytes)};
    upload->Unmap(0, &written);
    if (test_texture) {
        D3D12_TEXTURE_COPY_LOCATION linear{};
        linear.pResource = upload.Get();
        linear.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        linear.PlacedFootprint = footprint;
        D3D12_TEXTURE_COPY_LOCATION image{};
        image.pResource = texture.Get();
        image.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        image.SubresourceIndex = 0;
        list->CopyTextureRegion(&image, 0, 0, 0, &linear, nullptr);
        D3D12_RESOURCE_BARRIER barrier{};
        barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition.pResource = texture.Get();
        barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
        list->ResourceBarrier(1, &barrier);
        // The preparation queue is drained below before ExternalCopy reads it.
    } else {
        list->CopyBufferRegion(destination, 0, upload.Get(), 0, bytes);
    }
    hr = list->Close();
    result("Close(copy-list)", hr);
    if (FAILED(hr)) return;
    ID3D12CommandList* lists[] = {list.Get()};
    queue->ExecuteCommandLists(1, lists);
    hr = queue->Signal(fence.Get(), 1);
    result("Signal(copy-fence)", hr);
    // Never return/free backing pages while submitted work could still use them.
    // A failed signal without device removal cannot safely retire allocations.
    if (FAILED(hr)) {
        while (SUCCEEDED(device->GetDeviceRemovedReason())) Sleep(100);
        result("GetDeviceRemovedReason(after-signal-failure)", device->GetDeviceRemovedReason());
        return;
    }
    while (fence->GetCompletedValue() < 1) {
        if (FAILED(device->GetDeviceRemovedReason())) {
            result("GetDeviceRemovedReason(copy-wait)", device->GetDeviceRemovedReason());
            return;
        }
        Sleep(1);
    }
    if (fence->GetCompletedValue() == std::numeric_limits<UINT64>::max() ||
        FAILED(device->GetDeviceRemovedReason())) {
        result("GetDeviceRemovedReason(copy-completion)", device->GetDeviceRemovedReason());
        return;
    }
    if (test_texture) {
        viewflow::reverse::d12::ExternalCopy copy;
        hr = copy.initialize(device);
        result("ExternalCopy::initialize", hr);
        if (FAILED(hr)) { std::printf("external_copy diagnostic=%s\n", copy.diagnostic()); return; }
        for(unsigned pass=0;pass<2;++pass) {
        // No GPU work remains before each clear. A stale completion/fence value
        // cannot pass by leaving the previous successful frame in memory.
        std::memset(cpu,0,static_cast<SIZE_T>(bytes));
        hr = copy.submit(texture.Get(), destination_owner);
        result("ExternalCopy::submit(texture-to-external-buffer)", hr);
        std::printf("external_copy diagnostic=%s preparation=separate-queue-drained scope=correctness-not-performance\n",
                    copy.diagnostic());
        if (FAILED(hr) && !copy.in_flight()) return;
        viewflow::reverse::d12::ExternalCopy::Status status;
        do { status = copy.wait(100); }
        while (status == viewflow::reverse::d12::ExternalCopy::Status::pending);
        result("ExternalCopy::completion", copy.last_error());
        if (status != viewflow::reverse::d12::ExternalCopy::Status::complete) return;
        UINT64 mismatches=0;
        const auto* observed=static_cast<const volatile unsigned char*>(cpu);
        for(UINT64 i=0;i<bytes;++i)if(observed[i]!=pattern(i))++mismatches;
        std::printf("external_copy_reuse pass=%u bytes=%llu mismatches=%llu result=%s\n",
            pass+1,static_cast<unsigned long long>(bytes),
            static_cast<unsigned long long>(mismatches),mismatches?"failed":"passed");
        if(mismatches)return;
        }
    }
    const auto* actual = static_cast<const volatile unsigned char*>(cpu);
    UINT64 mismatches = 0;
    UINT64 first = bytes;
    for (UINT64 i = 0; i < bytes; ++i) {
        if (actual[i] != pattern(i)) { if (!mismatches) first = i; ++mismatches; }
    }
    std::printf("%s_gpu_copy pattern=%s offset=0 bytes=%llu mismatches=%llu first_mismatch=%llu result=%s\n",
        test_texture ? "private_texture_6k" : scratch ? "ivshmem_scratch" : "private",
        test_texture ? "(x*17+y*29+channel*61+(x>>8)+(y>>8))&255" : "(i*37+(i>>8)+91)&255",
        static_cast<unsigned long long>(bytes), static_cast<unsigned long long>(mismatches),
        static_cast<unsigned long long>(first), mismatches ? "failed" : "passed");
}

void inspect(IDXGIAdapter1* adapter, bool test_heap, bool test_copy, std::shared_ptr<ScratchMapping> scratch_owner = {}, bool test_texture = false) {
    auto pages = std::make_shared<PrivatePages>();
    void* scratch = scratch_owner ? scratch_owner->map.ptr : nullptr;
    ComPtr<ID3D12Device> device;
    HRESULT hr = D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0,
                                  IID_PPV_ARGS(device.GetAddressOf()));
    result("D3D12CreateDevice", hr);
    if (FAILED(hr)) return;
    ComPtr<ID3D12Device3> device3;
    hr = device.As(&device3);
    result("QueryInterface(ID3D12Device3)", hr);
    D3D12_FEATURE_DATA_D3D12_OPTIONS options{};
    const HRESULT options_hr = device->CheckFeatureSupport(
        D3D12_FEATURE_D3D12_OPTIONS, &options, sizeof(options));
    result("CheckFeatureSupport(OPTIONS)", options_hr);
    if (SUCCEEDED(options_hr))
        std::printf("CrossAdapterRowMajorTextureSupported=%u ResourceHeapTier=%u\n",
                    unsigned(options.CrossAdapterRowMajorTextureSupported),
                    unsigned(options.ResourceHeapTier));
    // Query copy layout only; even the 16K case allocates no pixel storage.
    struct Extent {UINT width,height;};
    for(const auto extent : {Extent{6144,3456},Extent{6143,3456},Extent{16384,16384}}) {
        D3D12_RESOURCE_DESC texture{};
        texture.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        texture.Width=extent.width;texture.Height=extent.height;
        texture.DepthOrArraySize=1;texture.MipLevels=1;
        texture.Format=DXGI_FORMAT_B8G8R8A8_UNORM;texture.SampleDesc.Count=1;
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
        UINT rows=0;UINT64 row_bytes=0,total=0;
        device->GetCopyableFootprints(&texture,0,1,0,&footprint,&rows,&row_bytes,&total);
        const bool valid=total!=std::numeric_limits<UINT64>::max() &&
            rows==extent.height && row_bytes==UINT64(extent.width)*4 &&
            footprint.Footprint.RowPitch>=row_bytes;
        std::printf("bgra_footprint width=%u height=%u row_bytes=%llu row_pitch=%u total_bytes=%llu valid=%u tight=%u scope=layout-query-no-allocation\n",
            extent.width,extent.height,static_cast<unsigned long long>(row_bytes),
            footprint.Footprint.RowPitch,static_cast<unsigned long long>(total),
            unsigned(valid),unsigned(valid && footprint.Footprint.RowPitch==row_bytes));
    }
    if (!test_heap || FAILED(hr)) {
        result("GetDeviceRemovedReason", device->GetDeviceRemovedReason());
        return;
    }

    const UINT64 resource_bytes = test_texture ? UINT64(6144) * 3456 * 4 : 1024 * 1024;
    const SIZE_T allocation_bytes = test_texture
        ? static_cast<SIZE_T>((resource_bytes + 65535) & ~UINT64(65535)) : 4 * 1024 * 1024;
    constexpr std::uintptr_t alignment = 64 * 1024;
    void* import_address = scratch;
    if (!scratch) {
        pages->base = VirtualAlloc(nullptr, allocation_bytes,
                                  MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        import_address = pages->base;
        if (!import_address) {
            std::printf("VirtualAlloc error=%lu\n", GetLastError());
            result("GetDeviceRemovedReason", device->GetDeviceRemovedReason());
            return;
        }
    }
    if (reinterpret_cast<std::uintptr_t>(import_address) % alignment != 0) {
        std::printf("import_allocation alignment_check=failed\n");
        result("GetDeviceRemovedReason", device->GetDeviceRemovedReason());
        return;
    }
    std::printf("import_allocation scope=%s bytes=%llu alignment_check=65536\n",
                scratch ? "ivshmem-scratch" : "private",
                static_cast<unsigned long long>(scratch ? scratch_bytes : allocation_bytes));
    std::shared_ptr<viewflow::reverse::d12::ExternalHeap> heap;
    const char* diagnostic = nullptr;
    std::shared_ptr<void> backing = scratch ? std::static_pointer_cast<void>(scratch_owner)
                                            : std::static_pointer_cast<void>(pages);
    std::weak_ptr<void> backing_lifetime = backing;
    hr = viewflow::reverse::d12::ExternalHeap::open(device3.Get(), import_address,
        scratch ? scratch_bytes : allocation_bytes, std::move(backing), heap, diagnostic);
    std::printf("external_heap diagnostic=%s\n", diagnostic);
    result("OpenExistingHeapFromAddress", hr);
    if (SUCCEEDED(hr)) {
        // Remove caller ownership: the imported heap must now retain private RAM.
        pages.reset();
        scratch_owner.reset();
        const auto heap_desc = heap->description();
        std::printf("heap bytes=%llu alignment=%llu flags=0x%x\n",
                    static_cast<unsigned long long>(heap_desc.SizeInBytes),
                    static_cast<unsigned long long>(heap_desc.Alignment),
                    unsigned(heap_desc.Flags));
        D3D12_RESOURCE_DESC desc{};
        desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        desc.Alignment = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;
        desc.Width = resource_bytes;
        desc.Height = 1;
        desc.DepthOrArraySize = 1;
        desc.MipLevels = 1;
        desc.Format = DXGI_FORMAT_UNKNOWN;
        desc.SampleDesc.Count = 1;
        desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_CROSS_ADAPTER;
        std::shared_ptr<viewflow::reverse::d12::ExternalBuffer> buffer;
        hr = viewflow::reverse::d12::ExternalBuffer::create(heap, 0, desc,
            D3D12_RESOURCE_STATE_COPY_DEST, buffer, diagnostic);
        std::printf("external_buffer diagnostic=%s\n", diagnostic);
        result(test_texture ? "CreatePlacedResource(6K-BGRA-buffer,COPY_DEST,CROSS_ADAPTER)" :
               "CreatePlacedResource(1MiB,COPY_DEST,CROSS_ADAPTER)", hr);
        const auto placed_device_status=device->GetDeviceRemovedReason();
        result("GetDeviceRemovedReason(after-placed-resource)", placed_device_status);
        if (SUCCEEDED(hr) && SUCCEEDED(placed_device_status) && test_copy)
            copy_private(device.Get(), buffer, import_address, scratch != nullptr, test_texture);
        if (buffer) {
            heap.reset(); // Buffer must keep its heap and mapping alive on its own.
            std::printf("external_owner retained_by_buffer=%u\n", unsigned(!backing_lifetime.expired()));
            buffer.reset(); // copy_private has drained the fence before returning.
            std::printf("external_owner scope=%s released_after_buffer=%u\n",
                        scratch ? "scratch-main-owner-retained" : "private",
                        unsigned(backing_lifetime.expired()));
        }
    }
    result("GetDeviceRemovedReason", device->GetDeviceRemovedReason());
}
} // namespace

int main(int argc, char** argv) {
    bool test_heap = false;
    bool test_copy = false;
    bool test_scratch = false;
    bool test_texture = false;
    unsigned char scratch_cache = 2;
    UINT64 bus = 0, slot = 0, expected_bytes = 0;
    if (argc == 2 && std::strcmp(argv[1], "--test-private-heap") == 0)
        test_heap = true;
    else if (argc == 2 && std::strcmp(argv[1], "--test-private-copy") == 0)
        test_heap = test_copy = true;
    else if (argc == 2 && std::strcmp(argv[1], "--test-private-texture") == 0)
        test_texture = test_heap = test_copy = true;
    else if (argc == 5 && (std::strcmp(argv[1], "--test-ivshmem-copy") == 0 || std::strcmp(argv[1], "--test-ivshmem-cached-copy") == 0)) {
        if (std::strcmp(argv[1], "--test-ivshmem-cached-copy") == 0) scratch_cache = 1;
        if (!number(argv[2], bus) || bus > 255 || !number(argv[3], slot) || slot > 31 ||
            !number(argv[4], expected_bytes) || expected_bytes != scratch_bytes) {
            std::fprintf(stderr, "Scratch requires bus 0..255, slot 0..31, expected-bytes=16777216\n");
            return 2;
        }
        test_scratch = test_heap = test_copy = true;
    }
    else if (argc != 1) {
        std::fprintf(stderr, "Usage: viewflow_d12_heap_probe [--test-private-heap | --test-private-copy | --test-private-texture | --test-ivshmem-copy <bus> <slot> <expected-bytes> | --test-ivshmem-cached-copy <bus> <slot> <expected-bytes>]\n");
        return 2;
    }
    std::printf("scope=%s no_ivshmem=%u no_gpu_commands=%u\n",
                test_texture ? "private-texture-6k-copy" : test_scratch ? "ivshmem-scratch-copy" : test_copy ? "private-ram-copy" : test_heap ? "private-allocation-import" : "capability-query",
                unsigned(!test_scratch), unsigned(!test_copy));
    // This handle outlives every adapter/device/resource in inspect().
    auto scratch = test_scratch ? std::make_shared<ScratchMapping>() : nullptr;
    if (test_scratch && !scratch->open(static_cast<DWORD>(bus), static_cast<DWORD>(slot), scratch_cache)) {
        std::fprintf(stderr, "scratch_open failed error=%lu; no copy submitted\n", GetLastError());
        return 1;
    }
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()));
    result("CreateDXGIFactory1", hr);
    if (FAILED(hr)) return 1;
    unsigned hardware_count = 0;
    for (UINT index = 0;; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        hr = factory->EnumAdapters1(index, adapter.GetAddressOf());
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr)) { result("EnumAdapters1", hr); return 1; }
        DXGI_ADAPTER_DESC1 desc{};
        hr = adapter->GetDesc1(&desc);
        if (FAILED(hr)) { result("GetDesc1", hr); continue; }
        if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
        ++hardware_count;
        char name[512]{};
        WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1,
                            name, sizeof(name), nullptr, nullptr);
        std::printf("adapter index=%u name=\"%s\" vendor=0x%04x device=0x%04x luid=%08lx:%08lx\n",
                    index, name, desc.VendorId, desc.DeviceId,
                    static_cast<unsigned long>(desc.AdapterLuid.HighPart),
                    static_cast<unsigned long>(desc.AdapterLuid.LowPart));
        inspect(adapter.Get(), test_heap, test_copy, scratch, test_texture);
    }
    std::printf("hardware_adapters=%u result_scope=capability-only "
                "scratch_requested=%u production_ivshmem=untested\n", hardware_count, unsigned(test_scratch));
    // Individual capability failures are observations; enumeration failure is fatal.
    return hardware_count ? 0 : 1;
}
