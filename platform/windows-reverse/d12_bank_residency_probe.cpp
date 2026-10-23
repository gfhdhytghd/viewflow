// Explicit 1 GiB bank import-only residency probe: no pixel/metadata access,
// resource creation or GPU commands. Operator must stop the active bank writer.
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
using Microsoft::WRL::ComPtr;
namespace {
constexpr UINT64 expected_bytes = UINT64(1073741824);
constexpr GUID interface_id = {0xdf576976,0x569d,0x4672,{0x95,0xa0,0xf5,0x7e,0x4e,0xa0,0xb2,0x10}};
struct DriverMap { UINT16 peer; UINT64 size; PVOID ptr; UINT16 vectors; };
static_assert(sizeof(void*) == 8 && sizeof(DriverMap) == 32);
void report(const char* stage, HRESULT hr) { std::printf("%s hr=0x%08lx\n", stage, static_cast<unsigned long>(hr)); }
struct Mapping {
    HANDLE handle = INVALID_HANDLE_VALUE;
    DriverMap map{};
    ~Mapping() { if (handle != INVALID_HANDLE_VALUE) { CloseHandle(handle); std::printf("bank mapping closed\n"); } }
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
int run(UINT bus, UINT slot, UINT adapter_index) {
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
    std::shared_ptr<viewflow::reverse::d12::ExternalHeap> heap;
    const char* diagnostic = nullptr;
    hr = viewflow::reverse::d12::ExternalHeap::open(device.Get(), mapping->map.ptr, expected_bytes, mapping, heap, diagnostic);
    report("ExternalHeap::open(import only)", hr); std::printf("diagnostic=%s\n", diagnostic);
    if (FAILED(hr)) { report("GetDeviceRemovedReason(import failure)", device->GetDeviceRemovedReason()); return 1; }
    std::printf("heap imported hold_ms=20000 bytes=%llu heap_bytes=%llu no_pixel_access=1 no_gpu_commands=1\n",
        static_cast<unsigned long long>(expected_bytes), static_cast<unsigned long long>(heap->description().SizeInBytes));
    std::fflush(stdout);
    Sleep(20000);
    hr = device->GetDeviceRemovedReason(); report("GetDeviceRemovedReason(after hold)", hr);
    heap.reset(); std::printf("heap released\n");
    device.Reset();
    mapping.reset();
    std::printf("probe complete residency=requires-host-observation transport=untested\n");
    return SUCCEEDED(hr) ? 0 : 1;
}
}
int main(int argc, char** argv) {
    UINT bus = 0, slot = 0, adapter = 0;
    if (argc != 5 || std::strcmp(argv[1], "--import-only") || !number(argv[2], bus) || bus > 255 ||
        !number(argv[3], slot) || slot > 31 || !number(argv[4], adapter)) {
        std::fprintf(stderr, "Usage: viewflow_d12_bank_residency_probe --import-only <bus> <slot> <adapter-index>\n"); return 2;
    }
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("scope=explicit-one-bank-import-only expected_bytes=1073741824 cache=1 hold_ms=20000\n");
    try { return run(bus, slot, adapter); }
    catch (const std::bad_alloc&) { report("probe allocation", E_OUTOFMEMORY); return 1; }
}
