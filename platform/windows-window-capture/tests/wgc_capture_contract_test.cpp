#include "wgc_capture_contract.hpp"

#include <cassert>
#include <cstdint>
#include <limits>

using namespace viewflow::windows_capture;

int main() {
    static_assert(classifyStartupHresult(hresult_access_denied) ==
                  CaptureFailure::access_denied_or_protected);
    static_assert(classifyStartupHresult(hresult_not_implemented) ==
                  CaptureFailure::platform_unsupported);
    static_assert(classifyStartupHresult(hresult_not_supported) ==
                  CaptureFailure::platform_unsupported);
    static_assert(validContentExtent(1, 1));
    static_assert(!validContentExtent(0, 1));
    static_assert(!validContentExtent(8193, 1));
    static_assert(!validContentExtent(4097, 4097));
    static_assert(nextGeometryEpoch(0, false) == 0);
    static_assert(nextGeometryEpoch(0, true) == 1);
    static_assert(nextGeometryEpoch(std::numeric_limits<std::uint64_t>::max(),
                                    true) == 0);
    static_assert(validSystemRelativeTime100ns(0));
    static_assert(validSystemRelativeTime100ns(1));
    static_assert(!validSystemRelativeTime100ns(-1));

    const CaptureLimits compact{4, 4, 16};
    assert(validContentExtent(4, 4, compact));
    assert(!validContentExtent(4, 5, compact));
    assert(!validContentExtent(3, 6, compact));

    const NativeWindowBounds ordinary{1, 2, 3, 4, false};
    const NativeWindowBounds extended{1, 2, 3, 4, true};
    assert(ordinary != extended);
    return 0;
}
