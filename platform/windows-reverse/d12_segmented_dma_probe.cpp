// Explicit two-function 64 MiB scratch BAR experiment; never production slots.
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
#include <array>
#include <string>
#include "d12_external_heap.hpp"
#include "d12_segmented_copy.hpp"
#include "../reverse-common/segmented_bgra_copy.hpp"
using Microsoft::WRL::ComPtr;
namespace {
constexpr UINT64 expected_bytes = UINT64(64) << 20;
constexpr GUID interface_id = {0xdf576976,0x569d,0x4672,{0x95,0xa0,0xf5,0x7e,0x4e,0xa0,0xb2,0x10}};
struct DriverMap { UINT16 peer; UINT64 size; PVOID ptr; UINT16 vectors; };
static_assert(sizeof(void*) == 8 && sizeof(DriverMap) == 32);
void report(const char* stage, HRESULT hr) { std::printf("%s hr=0x%08lx\n", stage, static_cast<unsigned long>(hr)); }
struct Mapping {
    HANDLE handle = INVALID_HANDLE_VALUE;
    DriverMap map{};
    ~Mapping() { if (handle != INVALID_HANDLE_VALUE) { CloseHandle(handle); std::printf("bank mapping closed\n"); } }
    HRESULT open(DWORD requested_bus, DWORD requested_slot, DWORD requested_function) {
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
            if (bus == requested_bus && address == ((requested_slot << 16) | requested_function)) { ++matches; path = detail->DevicePath; }
        }
        std::printf("bank location bus=%lu slot=%lu function=%lu matches=%u\n", requested_bus, requested_slot, requested_function, matches);
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
struct SourceDrain {
    ID3D12Device* device;
    ID3D12CommandQueue* queue;
    ID3D12Fence* fence;
    bool active = false, signaled = false;
    ~SourceDrain() {
        while (active) {
            const HRESULT removed = device->GetDeviceRemovedReason();
            const auto completed = fence->GetCompletedValue();
            if (FAILED(removed) || completed == UINT64_MAX || (signaled && completed >= 1)) break;
            if (!signaled) signaled = SUCCEEDED(queue->Signal(fence, 1));
            Sleep(1);
        }
    }
};
bool copy6k(ID3D12Device3* device, const std::array<std::shared_ptr<viewflow::reverse::d12::ExternalHeap>,2>& heaps) {
    using namespace viewflow::reverse;
    const auto plan = plan_segmented_bgra(6144,3456);
    constexpr UINT64 bytes = UINT64(6144) * 3456 * 4;
    std::array<std::shared_ptr<d12::ExternalBuffer>,2> buffers{};
    D3D12_RESOURCE_DESC bd{};
    bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width = expected_bytes;
    bd.Alignment = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;
    bd.Height = 1; bd.DepthOrArraySize = 1; bd.MipLevels = 1; bd.SampleDesc.Count = 1;
    bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR; bd.Flags = D3D12_RESOURCE_FLAG_ALLOW_CROSS_ADAPTER;
    for (unsigned i=0;i<2;++i) {
        const char* diagnostic=nullptr;
        const HRESULT hr=d12::ExternalBuffer::create(heaps[i],0,bd,D3D12_RESOURCE_STATE_COPY_DEST,buffers[i],diagnostic);
        report("ExternalBuffer::create(segment)",hr);
        std::printf("segment=%u diagnostic=%s\n",i,diagnostic); if(FAILED(hr))return false;
    }
    ComPtr<ID3D12Resource> upload, texture;
    D3D12_HEAP_PROPERTIES hp{}; hp.Type=D3D12_HEAP_TYPE_UPLOAD;
    bd.Width=bytes; bd.Flags=D3D12_RESOURCE_FLAG_NONE;
    HRESULT hr=device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_NONE,&bd,D3D12_RESOURCE_STATE_GENERIC_READ,nullptr,IID_PPV_ARGS(upload.GetAddressOf()));
    report("CreateCommittedResource(upload)",hr); if(FAILED(hr))return false;
    D3D12_RESOURCE_DESC td{};
    td.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D; td.Width=6144; td.Height=3456;
    td.DepthOrArraySize=1; td.MipLevels=1; td.Format=DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count=1;
    hp.Type=D3D12_HEAP_TYPE_DEFAULT;
    hr=device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_NONE,&td,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_PPV_ARGS(texture.GetAddressOf()));
    report("CreateCommittedResource(DEFAULT6K)",hr); if(FAILED(hr))return false;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT full{}; UINT rows=0; UINT64 row_bytes=0,total=0;
    device->GetCopyableFootprints(&td,0,1,0,&full,&rows,&row_bytes,&total);
    if(full.Offset || full.Footprint.RowPitch!=24576 || total!=bytes || rows!=3456 || row_bytes!=24576) {
        std::printf("unexpected source footprint\n");return false;
    }
    void* mapped=nullptr; D3D12_RANGE none{0,0};
    hr=upload->Map(0,&none,&mapped);report("Map(source upload only)",hr);if(FAILED(hr))return false;
    for(UINT64 i=0;i<bytes;++i)static_cast<unsigned char*>(mapped)[i]=static_cast<unsigned char>((i*37+(i>>8)+91)&255);
    D3D12_RANGE written{0,static_cast<SIZE_T>(bytes)};upload->Unmap(0,&written);
    ComPtr<ID3D12CommandQueue> queue;ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> list;ComPtr<ID3D12Fence> fence;
    D3D12_COMMAND_QUEUE_DESC q{};q.Type=D3D12_COMMAND_LIST_TYPE_COPY;
    hr=device->CreateCommandQueue(&q,IID_PPV_ARGS(queue.GetAddressOf()));report("CreateCommandQueue",hr);if(FAILED(hr))return false;
    hr=device->CreateCommandAllocator(q.Type,IID_PPV_ARGS(allocator.GetAddressOf()));report("CreateCommandAllocator",hr);if(FAILED(hr))return false;
    hr=device->CreateCommandList(0,q.Type,allocator.Get(),nullptr,IID_PPV_ARGS(list.GetAddressOf()));report("CreateCommandList",hr);if(FAILED(hr))return false;
    hr=device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(fence.GetAddressOf()));report("CreateFence",hr);if(FAILED(hr))return false;
    D3D12_TEXTURE_COPY_LOCATION from{}, to{};
    from.pResource=upload.Get();from.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;from.PlacedFootprint=full;
    to.pResource=texture.Get();to.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    list->CopyTextureRegion(&to,0,0,0,&from,nullptr);
    D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource=texture.Get();barrier.Transition.Subresource=D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore=D3D12_RESOURCE_STATE_COPY_DEST;barrier.Transition.StateAfter=D3D12_RESOURCE_STATE_COPY_SOURCE;
    list->ResourceBarrier(1,&barrier);
    for(const auto& region:plan)
        std::printf("copy plan segment=%u offset=%llu source=%u,%u extent=%ux%u pitch=%u bytes=%llu\n",
            region.segment,(unsigned long long)region.destination_offset,region.source_x,region.source_y,
            region.width,region.height,region.row_pitch,(unsigned long long)region.bytes);
    hr=list->Close();report("Close(copy commands)",hr);if(FAILED(hr))return false;
    SourceDrain producer{device, queue.Get(), fence.Get()};
    d12::SegmentedCopy segmented;
    hr=segmented.initialize(device);report("SegmentedCopy::initialize",hr);if(FAILED(hr))return false;
    ID3D12CommandList* commands[]={list.Get()};producer.active=true;queue->ExecuteCommandLists(1,commands);
    hr=queue->Signal(fence.Get(),1);producer.signaled=SUCCEEDED(hr);report("Signal(source preparation)",hr);
    if(FAILED(hr))return false; // Producer guard recovers/drains before source destruction.
    hr=segmented.submit(texture.Get(),buffers,fence.Get(),1);
    report("SegmentedCopy::submit",hr);
    std::printf("segmented helper commands=%u segments=%u diagnostic=%s producer_wait=GPU-only\n",
                segmented.command_count(),segmented.segment_count(),segmented.diagnostic());
    const bool submit_failed=FAILED(hr);
    if(submit_failed && !segmented.in_flight())return false;
    d12::SegmentedCopy::Status status;
    do {status=segmented.wait(100);} while(status==d12::SegmentedCopy::Status::pending);
    report("SegmentedCopy::completion",segmented.last_error());
    if(status!=d12::SegmentedCopy::Status::complete || submit_failed)return false;
    std::printf("segmented copy complete bytes=84934656 segments=2 destination_CPU_access=none pattern=(i*37+(i>>8)+91)&255 host_verify=required\n");
    return true;
}
int run(UINT bus,UINT slot,UINT f0,UINT f1,UINT ai,bool copy) {
    std::array<std::shared_ptr<Mapping>,2> maps{};
    ComPtr<IDXGIFactory1> factory;HRESULT hr=CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()));
    report("CreateDXGIFactory1",hr);if(FAILED(hr))return 1;
    ComPtr<IDXGIAdapter1> adapter;hr=factory->EnumAdapters1(ai,adapter.GetAddressOf());report("EnumAdapters1(selected)",hr);if(FAILED(hr))return 1;
    DXGI_ADAPTER_DESC1 ad{};hr=adapter->GetDesc1(&ad);report("GetDesc1",hr);if(FAILED(hr)||ad.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)return 1;
    std::printf("adapter index=%u luid=%08lx:%08lx\n",ai,(unsigned long)ad.AdapterLuid.HighPart,(unsigned long)ad.AdapterLuid.LowPart);
    ComPtr<ID3D12Device3> device;hr=D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(device.GetAddressOf()));
    report("D3D12CreateDevice",hr);if(FAILED(hr))return 1;
    std::array<std::shared_ptr<viewflow::reverse::d12::ExternalHeap>,2> heaps{};
    for(unsigned i=0;i<(copy?2u:1u);++i) {
        maps[i]=std::make_shared<Mapping>();hr=maps[i]->open(bus,slot,i?f1:f0);report("map exact segment",hr);if(FAILED(hr))return 1;
        const char* diagnostic=nullptr;
        hr=viewflow::reverse::d12::ExternalHeap::open(device.Get(),maps[i]->map.ptr,expected_bytes,maps[i],heaps[i],diagnostic);
        report("ExternalHeap::open(segment)",hr);std::printf("segment=%u diagnostic=%s\n",i,diagnostic);if(FAILED(hr))return 1;
    }
    bool passed=true;
    if(copy)passed=copy6k(device.Get(),heaps);
    else {std::printf("heap imported mode=import-one segment=0 bytes=67108864 hold_ms=20000\n");std::fflush(stdout);Sleep(20000);}
    hr=device->GetDeviceRemovedReason();report("GetDeviceRemovedReason(after experiment)",hr);
    for(auto& heap:heaps)heap.reset();device.Reset();for(auto& map:maps)map.reset();
    return passed && SUCCEEDED(hr)?0:1;
}
}
int main(int argc,char** argv) {
    UINT bus=0,slot=0,f0=0,f1=0,adapter=0;
    if(argc!=8 || std::strcmp(argv[1],"--scratch") || !number(argv[2],bus) || bus>255 ||
       !number(argv[3],slot) || slot<10 || slot>31 || !number(argv[4],f0) || f0>7 ||
       !number(argv[5],f1) || f1>7 || f0==f1 || !number(argv[6],adapter) ||
       (std::strcmp(argv[7],"import-one") && std::strcmp(argv[7],"6k-copy"))) {
        std::fprintf(stderr,"Usage: viewflow_d12_segmented_dma_probe --scratch <bus> <slot>=10..31 <first-function> <second-function> <adapter-index> <import-one|6k-copy>\n");return 2;
    }
    std::setvbuf(stdout,nullptr,_IONBF,0);
    std::printf("PRECONDITION host: two independent 64MiB BARs backed by same1GiB file at offsets0/67108864; RDM enables all used64MiB segments. Production forbidden; assertion not autoverified.\n");
    try{return run(bus,slot,f0,f1,adapter,!std::strcmp(argv[7],"6k-copy"));}
    catch(const std::exception& e){std::fprintf(stderr,"probe exception=%s\n",e.what());return 1;}
}
