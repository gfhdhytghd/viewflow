#include "VFTrackpadClient.h"
#include "VFTrackpadRoot.h"
#include "native_protocol.h"
#include <DriverKit/DriverKit.h>
#include <DriverKit/OSCollections.h>
struct VFTrackpadClient_IVars { VFTrackpadRoot *root; };
bool VFTrackpadClient::init() {
    if (!super::init()) return false;
    ivars = IONewZero(VFTrackpadClient_IVars, 1);
    return ivars != nullptr;
}
void VFTrackpadClient::free() {
    if (ivars) {
        OSSafeReleaseNULL(ivars->root);
        IOSafeDeleteNULL(ivars, VFTrackpadClient_IVars, 1);
    }
    super::free();
}
kern_return_t IMPL(VFTrackpadClient, Start) {
    auto kr = Start(provider, SUPERDISPATCH);
    if (kr) return kr;
    ivars->root = OSDynamicCast(VFTrackpadRoot, provider);
    if (!ivars->root) return kIOReturnBadArgument;
    ivars->root->retain();
    return kIOReturnSuccess;
}
kern_return_t IMPL(VFTrackpadClient, Stop) {
    if (ivars->root) {
        ivars->root->clientClosed(this);
        OSSafeReleaseNULL(ivars->root);
    }
    return Stop(provider, SUPERDISPATCH);
}
kern_return_t VFTrackpadClient::ExternalMethod(uint64_t selector,
    IOUserClientMethodArguments *a, const IOUserClientMethodDispatch *, OSObject *, void *) {
    if (!ivars->root) return kIOReturnNotAttached;
    if (!a || a->scalarInputCount || a->structureInputDescriptor ||
        a->structureOutputDescriptor || a->structureOutput) return kIOReturnBadArgument;
    if (selector == 0) {
        if (a->structureInput || a->scalarOutputCount != 16 || !a->scalarOutput)
            return kIOReturnBadArgument;
        ivars->root->status(a->scalarOutput);
        return kIOReturnSuccess;
    }
    if (a->scalarOutputCount) return kIOReturnBadArgument;
    if (selector == 1) {
        if (!a->structureInput || a->structureInput->getLength() != vf_native::wire_size)
            return kIOReturnBadArgument;
        return ivars->root->submit(this,
            static_cast<const uint8_t *>(a->structureInput->getBytesNoCopy()), vf_native::wire_size);
    }
    if (selector == 2) {
        if (a->structureInput) return kIOReturnBadArgument;
        return ivars->root->releaseInput(this);
    }
    return kIOReturnUnsupported;
}
