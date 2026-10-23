#pragma once
#include <windows.h>
#include <winioctl.h>
#include <setupapi.h>
#include <string>
#include <vector>
#include <algorithm>
#include <tuple>
#include <cstdio>
#include <stdexcept>
#include "../reverse-common/shared_frames.hpp"
#include "../reverse-common/dma_bank_layout.hpp"

namespace viewflow::reverse::shm {
// ABI from virtio-win ivshmem/Public.h. Use the signed virtio-win driver.
inline constexpr GUID interface_id={0xdf576976,0x569d,0x4672,{0x95,0xa0,0xf5,0x7e,0x4e,0xa0,0xb2,0x10}};
struct DriverMap {UINT16 peer;UINT64 size;PVOID ptr;UINT16 vectors;};
static_assert(sizeof(void*)==8 && sizeof(DriverMap)==32);
class Mapping {
    struct Device {std::wstring path;DWORD bus{},address{};};
    struct Region {
        HANDLE device=INVALID_HANDLE_VALUE;DriverMap map{};
        ~Region(){if(device!=INVALID_HANDLE_VALUE)CloseHandle(device);}
        void open_device(const Device& d){
            device=CreateFileW(d.path.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,0,nullptr);
            if(device==INVALID_HANDLE_VALUE)throw std::runtime_error("IVSHMEM device open");
            std::uint8_t cached=1;DWORD returned{};
            if(!DeviceIoControl(device,CTL_CODE(FILE_DEVICE_UNKNOWN,0x802,METHOD_BUFFERED,FILE_ANY_ACCESS),&cached,1,&map,sizeof(map),&returned,nullptr) || returned!=sizeof(map) || !map.ptr)
                throw std::runtime_error("IVSHMEM mmap IOCTL");
        }
    } control_,banks_[slots];
    HANDLE owner_=nullptr;std::size_t capacity_{};bool gpu_dma_mapped_=false;
    std::vector<Device> inventory_;
    std::array<std::array<std::unique_ptr<Region>,dma_segments_per_bank>,slots> segments_{};
    DmaBankLayout* dma_layout_=nullptr;
    DmaBankLayout dma_identity_{};
    bool same_dma_identity() const noexcept {
        // Host descriptor is immutable for this mapping lifetime. A changed
        // generation/identity requires opening a new Mapping, never reusing BARs.
        return dma_layout_ && valid_dma_bank_layout(*dma_layout_) &&
            std::memcmp(dma_layout_,&dma_identity_,offsetof(DmaBankLayout,requested))==0;
    }
public:
    struct PixelBank {
        void* base{};
        std::uint64_t bytes{};
        std::shared_ptr<void> owner;
    };
    // Only separately mapped banks can be imported at heap offset zero. The
    // retained Mapping also keeps control metadata and writer ownership alive.
    // This does not change cache policy or prove D3D12 support of this mapping.
    static PixelBank pixel_bank(const std::shared_ptr<Mapping>& mapping,unsigned index) {
        if(!mapping || !mapping->capacity_ || !mapping->gpu_dma_mapped_ || index>=slots)
            throw std::runtime_error("IVSHMEM GPU bank requires host DMA mapping declaration and valid slot");
        const auto& region=mapping->banks_[index];
        return {region.map.ptr,region.map.size,mapping};
    }
    bool supports_segmented_dma() const noexcept {return capacity_==dma_bank_capacity && same_dma_identity();}
    DmaMappingStatus request_segments(unsigned bank,std::uint64_t bytes) noexcept {
        if(!supports_segmented_dma())return DmaMappingStatus::invalid;
        return request_dma_segments(*dma_layout_,bank,bytes);
    }
    // Segmented and CPU full-BAR virtual addresses differ. The immutable host
    // descriptor declares that each segment aliases bank offset index*64MiB.
    static PixelBank segment(const std::shared_ptr<Mapping>& mapping,unsigned bank,unsigned index) {
        if(!mapping || !mapping->supports_segmented_dma() || bank>=slots || index>=dma_segments_per_bank)
            throw std::runtime_error("IVSHMEM segmented mapping identity/index");
        if(!(std::atomic_ref(mapping->dma_layout_->ready.masks[bank]).load(std::memory_order_acquire)&(1ULL<<index)))
            throw std::runtime_error("IVSHMEM segment not host DMA ready");
        auto& cached=mapping->segments_[bank][index];
        if(!cached) {
            const auto address=dma_segment_address(mapping->dma_identity_.first_slot,bank,index);
            const auto found=std::find_if(mapping->inventory_.begin(),mapping->inventory_.end(),[&](const Device& d){
                return d.bus==mapping->dma_identity_.bus && d.address==address;});
            if(found==mapping->inventory_.end())throw std::runtime_error("IVSHMEM exact segment BDF missing");
            auto candidate=std::make_unique<Region>();candidate->open_device(*found);
            if(candidate->map.size!=dma_segment_bytes)throw std::runtime_error("IVSHMEM segment must be exactly 64MiB");
            cached=std::move(candidate);
        }
        return {cached->map.ptr,cached->map.size,mapping};
    }
    explicit Mapping(unsigned index) {
        const auto name=L"Local\\Viewflow-IVSHMEM-"+std::to_wstring(index);
        owner_=CreateMutexW(nullptr,FALSE,name.c_str());
        if(!owner_)throw std::runtime_error("IVSHMEM owner mutex");
        const auto wait=WaitForSingleObject(owner_,0);
        if(wait!=WAIT_OBJECT_0 && wait!=WAIT_ABANDONED){CloseHandle(owner_);owner_=nullptr;throw std::runtime_error("IVSHMEM writer already active");}
        try {
            const auto info=SetupDiGetClassDevsW(&interface_id,nullptr,nullptr,DIGCF_PRESENT|DIGCF_DEVICEINTERFACE);
            if(info==INVALID_HANDLE_VALUE)throw std::runtime_error("IVSHMEM driver enumeration");
            struct List {HDEVINFO info;~List(){SetupDiDestroyDeviceInfoList(info);}} list{info};
            std::vector<Device> devices;
            for(DWORD i=0;;++i){
                SP_DEVICE_INTERFACE_DATA iface{};iface.cbSize=sizeof(iface);
                if(!SetupDiEnumDeviceInterfaces(info,nullptr,&interface_id,i,&iface)){
                    if(GetLastError()!=ERROR_NO_MORE_ITEMS)throw std::runtime_error("IVSHMEM enumeration failed");
                    break;
                }
                DWORD size{};SetupDiGetDeviceInterfaceDetailW(info,&iface,nullptr,0,&size,nullptr);
                std::vector<std::uint8_t> buffer(size);auto* detail=reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(buffer.data());
                if(size<sizeof(*detail))throw std::runtime_error("IVSHMEM device path");
                detail->cbSize=sizeof(*detail);SP_DEVINFO_DATA dev{};dev.cbSize=sizeof(dev);
                if(!SetupDiGetDeviceInterfaceDetailW(info,&iface,detail,size,nullptr,&dev))throw std::runtime_error("IVSHMEM device detail");
                Device d;d.path=detail->DevicePath;
                if(!SetupDiGetDeviceRegistryPropertyW(info,&dev,SPDRP_BUSNUMBER,nullptr,reinterpret_cast<BYTE*>(&d.bus),sizeof(d.bus),nullptr) ||
                   !SetupDiGetDeviceRegistryPropertyW(info,&dev,SPDRP_ADDRESS,nullptr,reinterpret_cast<BYTE*>(&d.address),sizeof(d.address),nullptr))
                    throw std::runtime_error("IVSHMEM PCI location");
                devices.push_back(std::move(d));
            }
            std::sort(devices.begin(),devices.end(),[](const Device& a,const Device& b){return std::tie(a.bus,a.address)<std::tie(b.bus,b.address);});
            if(index>=devices.size())throw std::runtime_error("IVSHMEM device not installed");
            control_.open_device(devices[index]);
            if(control_.map.size<header_bytes)throw std::runtime_error("IVSHMEM control extent");
            BankLayout layout{};std::memcpy(&layout,static_cast<std::uint8_t*>(control_.map.ptr)+bank_layout_offset,sizeof(layout));
            if(layout.magic==bank_magic){
                if(layout.capacity<4096 || layout.capacity>max_slot_bytes || layout.capacity%64)throw std::runtime_error("IVSHMEM bank capacity");
                capacity_=layout.capacity;
                gpu_dma_mapped_=(layout.reserved & bank_gpu_dma_mapped)!=0;
                if((layout.reserved&(bank_memfd|bank_gpu_segmented))==(bank_memfd|bank_gpu_segmented) &&
                    capacity_==dma_bank_capacity && control_.map.size>=dma_bank_layout_offset+sizeof(DmaBankLayout)) {
                    auto* candidate=reinterpret_cast<DmaBankLayout*>(static_cast<std::uint8_t*>(control_.map.ptr)+dma_bank_layout_offset);
                    if(valid_dma_bank_layout(*candidate)) {
                        std::memcpy(&dma_identity_,candidate,offsetof(DmaBankLayout,requested));dma_layout_=candidate;
                    }
                }
                for(unsigned i=0;i<slots;++i){
                    auto d=std::find_if(devices.begin(),devices.end(),[&](const Device& d){return d.bus==layout.bus && d.address==layout.addresses[i];});
                    if(d==devices.end())throw std::runtime_error("IVSHMEM pixel bank missing");
                    banks_[i].open_device(*d);
                    if(banks_[i].map.size<capacity_)throw std::runtime_error("IVSHMEM pixel bank extent");
                }
            }
            inventory_=std::move(devices);
            frames().recover(true);
            std::fprintf(stderr,"ivshmem-mapped bytes=%llu device=%u banks=%u capacity=%llu\n",static_cast<unsigned long long>(control_.map.size),index,capacity_?slots:0,static_cast<unsigned long long>(capacity_));
        }catch(...){ReleaseMutex(owner_);CloseHandle(owner_);owner_=nullptr;throw;}
    }
    ~Mapping(){if(owner_){ReleaseMutex(owner_);CloseHandle(owner_);}}
    Mapping(const Mapping&)=delete;Mapping& operator=(const Mapping&)=delete;
    bool gpu_dma_mapped() const noexcept {return capacity_ && gpu_dma_mapped_;}
    Frames frames(){
        if(!capacity_)return Frames(control_.map.ptr,static_cast<std::size_t>(control_.map.size));
        std::array<void*,slots> banks{};for(unsigned i=0;i<slots;++i)banks[i]=banks_[i].map.ptr;
        return Frames(control_.map.ptr,static_cast<std::size_t>(control_.map.size),banks,capacity_);
    }
};
}
