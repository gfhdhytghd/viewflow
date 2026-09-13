#include "VFTrackpad.h"
#include "native_descriptor.h"
#include "native_protocol.h"
#include <DriverKit/DriverKit.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IODMACommand.h>
#include <DriverKit/IOMemoryMap.h>
#include <DriverKit/OSData.h>
#include <DriverKit/OSCollections.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSString.h>
#include <DriverKit/OSNumber.h>
#include <os/log.h>
struct VFTrackpad_IVars { vf_native::Features features; };
bool VFTrackpad::init() {
    if(!super::init())return false;
    ivars=IONewZero(VFTrackpad_IVars,1);
    if(!ivars)return false;
    // IONewZero allocates raw zeroed storage without C++ member initializers.
    ivars->features.mode=8;
    return true;
}
void VFTrackpad::free() {
    if(ivars)IOSafeDeleteNULL(ivars,VFTrackpad_IVars,1);
    super::free();
}
bool VFTrackpad::handleStart(IOService *provider) {
    os_log(OS_LOG_DEFAULT,"Viewflow native MT bridge with CPU report access: starting without input");
    return super::handleStart(provider);
}
static bool string_property(OSDictionary *d,const char *key,const char *value) {
    auto s=OSString::withCString(value);if(!s)return false;
    bool ok=OSDictionarySetValue(d,key,s);s->release();return ok;
}
static bool number_property(OSDictionary *d,const char *key,uint32_t value) {
    auto n=OSNumber::withNumber(value,32);if(!n)return false;
    bool ok=OSDictionarySetValue(d,key,n);n->release();return ok;
}
OSDictionary *VFTrackpad::newDeviceDescription() {
    auto d=OSDictionary::withCapacity(12);if(!d)return nullptr;
    // Matches this Mac's native trackpad bridge personality (parser 1000/39).
    // Product, manufacturer and serial identify this virtual implementation.
    bool ok=string_property(d,"Product","Viewflow Native MT Protocol Experiment") &&
        string_property(d,"Manufacturer","Viewflow") &&
        string_property(d,"SerialNumber","Viewflow-Native-MT-v13") &&
        string_property(d,"Transport","Virtual") &&
        string_property(d,"HIDDefaultBehavior","Trackpad") &&
        number_property(d,"VendorID",0x5ac) && number_property(d,"ProductID",2) &&
        number_property(d,"VersionNumber",0x804) &&
        number_property(d,"ReportInterval",8000);
    OSDictionarySetValue(d,"RegisterService",kOSBooleanTrue);
    if(!ok){d->release();return nullptr;}return d;
}
OSData *VFTrackpad::newReportDescriptor() {
    return OSData::withBytes(vf_native_descriptor,sizeof(vf_native_descriptor));
}
kern_return_t VFTrackpad::submitBytes(const uint8_t *bytes,uint32_t length) {
    if(!bytes || length<12 || length>vf_native::max_hid_size || (length-12)%9 || bytes[0]!=2)
        return kIOReturnBadArgument;
    IOBufferMemoryDescriptor *buffer=nullptr;
    auto kr=IOBufferMemoryDescriptor::Create(kIOMemoryDirectionOut,length,0,&buffer);
    if(kr)return kr;
    uint64_t address=0,capacity=0;kr=buffer->Map(0,0,0,0,&address,&capacity);
    if(!kr && capacity<length)kr=kIOReturnNoSpace;
    if(!kr){memcpy(reinterpret_cast<void *>(address),bytes,length);
        kr=handleReport(mach_absolute_time(),buffer,length,kIOHIDReportTypeInput,0);}
    buffer->release();return kr;
}
// Public DriverKit CPU access for report descriptors that cannot be mapped into
// the dext. Only the caller-provided descriptor is prepared; no device DMA runs.
static kern_return_t copy_report(IOService *device,IOMemoryDescriptor *report,
    uint8_t *bytes,size_t length,bool write) {
    IOBufferMemoryDescriptor *local=nullptr;
    IODMACommand *command=nullptr;
    uint64_t address=0,capacity=0,flags=0;
    uint32_t count=32;
    IOAddressSegment segments[32]={};
    IODMACommandSpecification spec={};spec.maxAddressBits=64;
    bool prepared=false;
    auto kr=IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut,length,0,&local);
    if(!kr)kr=local->Map(0,0,0,0,&address,&capacity);
    if(!kr && capacity<length)kr=kIOReturnNoSpace;
    if(!kr && write)memcpy(reinterpret_cast<void *>(address),bytes,length);
    if(!kr)kr=IODMACommand::Create(device,0,&spec,&command);
    if(!kr){kr=command->PrepareForDMA(0,report,0,length,&flags,&count,segments);prepared=!kr;}
    if(!kr)kr=command->PerformOperation(write?kIODMACommandPerformOperationOptionWrite:
        kIODMACommandPerformOperationOptionRead,0,length,0,local);
    if(!kr && !write)memcpy(bytes,reinterpret_cast<void *>(address),length);
    if(prepared){auto done=command->CompleteDMA(0);if(!kr)kr=done;}
    if(command)command->release();
    if(local)local->release();
    os_log(OS_LOG_DEFAULT,"Viewflow MT CPU copy write=%d length=%zu prepared=%d status=0x%x",write,length,prepared,kr);
    return kr;
}
kern_return_t VFTrackpad::getReport(IOMemoryDescriptor *report,IOHIDReportType reportType,
    IOOptionBits options,uint32_t completionTimeout,OSAction *action) {
    (void)completionTimeout;
    uint8_t bytes[96]={};uint8_t id=options&0xff;
    size_t n=ivars->features.get(id,bytes);
    uint64_t address=0,capacity=0,length=0;
    IOMemoryMap *mapping=nullptr;
    auto kr=report ? report->GetLength(&length) : kIOReturnBadArgument;
    if(!kr && !n)kr=kIOReturnUnsupported;
    if(!kr && length<n)kr=kIOReturnNoSpace;
    if(!kr){
        kr=report->CreateMapping(0,0,0,0,0,&mapping);
        if(kr)kr=copy_report(this,report,bytes,n,true);
        else {
            address=mapping->GetAddress();capacity=mapping->GetLength();
            if(capacity<n)kr=kIOReturnNoSpace;
            else memcpy(reinterpret_cast<void *>(address),bytes,n);
        }
    }
    os_log(OS_LOG_DEFAULT,"Viewflow MT getReport id=%u type=%u length=%llu capacity=%llu bytes=%zu status=0x%x action=%d",
        id,static_cast<unsigned>(reportType),length,capacity,n,kr,action!=nullptr);
    // _ProcessReport is asynchronous even for a synchronous kernel caller.
    // Complete failed requests too; otherwise action disposal masks the original
    // failure as kIOReturnAborted in AppleUserHIDDevice.
    if(mapping)mapping->release();
    if(action)CompleteReport(action,kr,kr ? 0 : static_cast<uint32_t>(n));
    return kr;
}
kern_return_t VFTrackpad::setReport(IOMemoryDescriptor *report,IOHIDReportType reportType,
    IOOptionBits options,uint32_t completionTimeout,OSAction *action) {
    (void)completionTimeout;
    uint64_t address=0,capacity=0,length=0;
    IOMemoryMap *mapping=nullptr;
    auto kr=report ? report->GetLength(&length) : kIOReturnBadArgument;
    uint8_t local[512]={};
    if(!kr){
        kr=report->CreateMapping(kIOMemoryMapReadOnly,0,0,0,0,&mapping);
        if(kr){
            if(length>sizeof(local))kr=kIOReturnNoSpace;
            else {kr=copy_report(this,report,local,length,false);address=reinterpret_cast<uint64_t>(local);capacity=length;}
        } else {address=mapping->GetAddress();capacity=mapping->GetLength();}
    }
    if(!kr && capacity<length)kr=kIOReturnNoSpace;
    uint8_t id=options&0xff;
    if(!kr && !ivars->features.set(id,reinterpret_cast<const uint8_t *>(address),length))
        kr=kIOReturnUnsupported;
    os_log(OS_LOG_DEFAULT,"Viewflow MT setReport id=%u type=%u length=%llu capacity=%llu status=0x%x action=%d",
        id,static_cast<unsigned>(reportType),length,capacity,kr,action!=nullptr);
    if(mapping)mapping->release();
    if(action)CompleteReport(action,kr,kr ? 0 : static_cast<uint32_t>(length));
    return kr;
}
void VFTrackpad::featureStatus(uint64_t *v) {
    v[0]=ivars->features.gets;v[1]=ivars->features.sets;
    v[2]=ivars->features.unknown;v[3]=ivars->features.last_request;
}
