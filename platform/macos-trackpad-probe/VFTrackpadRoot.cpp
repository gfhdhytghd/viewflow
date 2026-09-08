#include "VFTrackpadRoot.h"
#include "VFTrackpad.h"
#include "native_protocol.h"
#include <DriverKit/DriverKit.h>
#include <DriverKit/IOUserClient.h>
#include <os/log.h>
struct VFTrackpadRoot_IVars {
    VFTrackpad *device;
    IOUserClient *owner; // non-owning, cleared by the client's Stop
    vf_native::State reports;
    uint64_t submitted, releases, errors;
};
bool VFTrackpadRoot::init() {
    if (!super::init()) return false;
    ivars = IONewZero(VFTrackpadRoot_IVars, 1);
    if (ivars) ivars->reports.init();
    return ivars != nullptr;
}
void VFTrackpadRoot::free() {
    if (ivars) {
        OSSafeReleaseNULL(ivars->device);
        IOSafeDeleteNULL(ivars, VFTrackpadRoot_IVars, 1);
    }
    super::free();
}
kern_return_t IMPL(VFTrackpadRoot, Start) {
    auto kr = Start(provider, SUPERDISPATCH);
    if (kr) return kr;
    IOService *device = nullptr;
    kr = Create(this, "TrackpadProperties", &device);
    os_log(OS_LOG_DEFAULT, "Viewflow trackpad Create: 0x%x", kr);
    if (!kr) {
        ivars->device = OSDynamicCast(VFTrackpad, device);
        if (!ivars->device) { device->release(); kr = kIOReturnBadArgument; }
    }
    if (!kr) kr = RegisterService();
    if (kr) Stop(provider, SUPERDISPATCH);
    return kr;
}
kern_return_t IMPL(VFTrackpadRoot, Stop) {
    if (ivars->device) {
        releaseInput(ivars->owner);
        ivars->owner = nullptr;
        ivars->device->Terminate(0);
        OSSafeReleaseNULL(ivars->device);
    }
    return Stop(provider, SUPERDISPATCH);
}
kern_return_t IMPL(VFTrackpadRoot, NewUserClient) {
    if (type != 0 || !userClient) return kIOReturnBadArgument;
    IOService *client = nullptr;
    auto kr = Create(this, "UserClientProperties", &client);
    if (kr) return kr;
    *userClient = OSDynamicCast(IOUserClient, client);
    if (!*userClient) { client->release(); return kIOReturnBadArgument; }
    return kIOReturnSuccess;
}
// All clients use this server's default serial dispatch queue; no custom queues.
kern_return_t VFTrackpadRoot::submit(IOUserClient *client, const uint8_t *bytes, uint32_t length) {
    if (!ivars->device) return kIOReturnNotAttached;
    if (!vf_native::valid(bytes, length)) return kIOReturnBadArgument;
    if (ivars->owner && ivars->owner != client) return kIOReturnExclusiveAccess;
    // Failed disconnect release is retried before a new producer starts.
    if (!ivars->owner && ivars->reports.active()) {
        auto kr = releaseInput(nullptr);
        if (kr) return kr;
    }
    auto kr = ivars->reports.apply(bytes, length, [this](const uint8_t *p, size_t n) {
        return ivars->device->submitBytes(p, static_cast<uint32_t>(n));
    });
    if (kr) ++ivars->errors;
    else { ivars->owner = client; ++ivars->submitted; }
    return kr;
}
kern_return_t VFTrackpadRoot::releaseInput(IOUserClient *client) {
    if (ivars->owner && ivars->owner != client) return kIOReturnExclusiveAccess;
    if (!ivars->device) return kIOReturnNotAttached;
    bool active = ivars->reports.active();
    auto kr = ivars->reports.release([this](const uint8_t *p, size_t n) {
        return ivars->device->submitBytes(p, static_cast<uint32_t>(n));
    });
    if (kr) ++ivars->errors;
    else { if (active) ++ivars->releases; ivars->owner = nullptr; }
    return kr;
}
void VFTrackpadRoot::clientClosed(IOUserClient *client) {
    if (ivars->owner != client) return;
    auto kr = releaseInput(client);
    if (kr) kr = releaseInput(client);
    ivars->owner = nullptr;
    os_log(OS_LOG_DEFAULT, "Viewflow trackpad disconnect release: 0x%x", kr);
}
void VFTrackpadRoot::status(uint64_t *v) {
    v[0] = vf_native::abi_version; v[1] = ivars->submitted; v[2] = ivars->releases;
    v[3] = ivars->errors; v[4] = ivars->reports.active() ? 1 : 0;
    v[5] = vf_native::down_count(ivars->reports.last); v[6] = ivars->reports.peak;
    v[7] = ivars->reports.clicks; v[8] = ivars->reports.last[1];
    if(ivars->device)ivars->device->featureStatus(v+9);
    v[13] = ivars->reports.last[0]; v[14] = vf_native::u32(ivars->reports.last+4);
    v[15] = 1; // native MT bridge profile
}
