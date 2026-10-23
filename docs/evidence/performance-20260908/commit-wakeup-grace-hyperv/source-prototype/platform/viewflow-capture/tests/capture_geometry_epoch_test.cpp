// SPDX-License-Identifier: GPL-3.0-only
#include "capture_geometry_epoch.hpp"
#include <cassert>

using namespace viewflow_capture;
int main() {
    CaptureGeometryEpoch state;
    auto main = planWindowCaptureGeometry(-20, 10, 800, 600, -100, 0, 1, 0);
    assert(state.observe(main, {}) == 1);
    assert(state.observe(main, {}) == 1);
    // Popups extend left/top and later disappear. Returning to a previous
    // rectangle never resurrects its epoch or an old input authorization.
    auto popup = planWindowCaptureGeometry(-70, -40, 850, 650, -100, 0, 1, 0);
    assert(state.observe(popup, {}) == 2);
    assert(state.observe(popup, {}) == 2);
    assert(state.observe(main, {}) == 3);
    auto scaled = planWindowCaptureGeometry(-20, 10, 800, 600, -100, 0, 2, 0);
    assert(scaled.x == main.x && scaled.width == main.width);
    assert(scaled.pixelWidth != main.pixelWidth);
    assert(state.observe(scaled, {}) == 4);
    CaptureGeometryEpoch::Input input{std::array<std::uint8_t, gpuwire::HCGI_BYTES>{}};
    assert(state.observe(scaled, input) == 5);
    assert(state.observe(scaled, input) == 5);
    // Fingerprint includes content bounds/extent even at fixed family bounds.
    (*input)[47] = 1;
    assert(state.observe(scaled, input) == 6);
    assert(state.observe(scaled, {}) == 7);
    auto invalid = scaled;
    invalid.x = std::numeric_limits<double>::quiet_NaN();
    assert(!state.observe(invalid, {}));
    invalid = scaled;
    invalid.pixelHeight = 0;
    assert(!state.observe(invalid, {}));
    invalid = scaled;
    invalid.supported = false;
    assert(!state.observe(invalid, {}));
    assert(state.observe(scaled, {}) == 7);
    constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    static_assert(nextCaptureGeometryEpoch(maximum, false) == maximum);
    static_assert(!nextCaptureGeometryEpoch(maximum, true));
    static_assert(nextCaptureGeometryEpoch(0, false) == 1);
}
