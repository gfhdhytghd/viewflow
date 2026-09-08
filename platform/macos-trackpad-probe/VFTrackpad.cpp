#include "VFTrackpad.h"
#include "native_descriptor.h"
#include "native_protocol.h"
#include <DriverKit/DriverKit.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/OSData.h>
#include <DriverKit/OSCollections.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSString.h>
#include <DriverKit/OSNumber.h>
#include <os/log.h>
struct VFTrackpad_IVars { vf_native::Features features; };
bool VFTrackpad::init() {
    if(!super::init())return false;
    ivars=IONewZero(VFTrackpad_IVars,1);return ivars!=nullptr;
}
void VFTrackpad::free() {
    if(ivars)IOSafeDeleteNULL(ivars,VFTrackpad_IVars,1);
    super::free();
}
bool VFTrackpad::handleStart(IOService *provider) {
    os_log(OS_LOG_DEFAULT,"Viewflow native MT bridge: starting without input");
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
    // The identifiers select macOS's observed Trackpad HID Bridge - MT parser.
    // Product and serial remain explicit about this being a Viewflow experiment.
    bool ok=string_property(d,"Product","Viewflow Native MT Protocol Experiment") &&
        string_property(d,"Manufacturer","Viewflow") &&
        string_property(d,"SerialNumber","Viewflow-Native-MT-v4") &&
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
kern_return_t VFTrackpad::getReport(IOMemoryDescriptor *report,IOHIDReportType reportType,
    IOOptionBits options,uint32_t completionTimeout,OSAction *action) {
    (void)reportType;(void)completionTimeout;
    uint8_t bytes[96]={};uint8_t id=options&0xff;
    size_t n=ivars->features.get(id,bytes);
    os_log(OS_LOG_DEFAULT,"Viewflow MT getReport id=%u bytes=%zu",id,n);
    if(!n)return kIOReturnUnsupported;
    uint64_t address=0,capacity=0;auto kr=report->Map(0,0,0,0,&address,&capacity);
    if(kr)return kr;
    if(capacity<n)return kIOReturnNoSpace;
    memcpy(reinterpret_cast<void *>(address),bytes,n);
    if(action)CompleteReport(action,kIOReturnSuccess,static_cast<uint32_t>(n));
    return kIOReturnSuccess;
}
kern_return_t VFTrackpad::setReport(IOMemoryDescriptor *report,IOHIDReportType reportType,
    IOOptionBits options,uint32_t completionTimeout,OSAction *action) {
    (void)reportType;(void)completionTimeout;
    uint64_t address=0,capacity=0;auto kr=report->Map(0,0,0,0,&address,&capacity);
    if(kr)return kr;
    uint8_t id=options&0xff;
    bool ok=ivars->features.set(id,reinterpret_cast<const uint8_t *>(address),capacity);
    os_log(OS_LOG_DEFAULT,"Viewflow MT setReport id=%u bytes=%llu supported=%d",id,capacity,ok);
    if(!ok)return kIOReturnUnsupported;
    if(action)CompleteReport(action,kIOReturnSuccess,static_cast<uint32_t>(capacity));
    return kIOReturnSuccess;
}
void VFTrackpad::featureStatus(uint64_t *v) {
    v[0]=ivars->features.gets;v[1]=ivars->features.sets;
    v[2]=ivars->features.unknown;v[3]=ivars->features.last_request;
}
