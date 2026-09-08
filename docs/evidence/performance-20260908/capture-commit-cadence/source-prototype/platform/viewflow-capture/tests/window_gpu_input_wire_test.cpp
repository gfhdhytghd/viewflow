// SPDX-License-Identifier: GPL-3.0-only
#include "window_gpu_wire.hpp"
#include <cassert>
#include <limits>
#include <string>
using namespace viewflow_capture::gpuwire;
int main() {
    InputGeometry input{0x1234, 0x5678, 9012, {-2.5, 3.25, 800, 600}, {400, 300}};
    std::array<std::uint8_t, HCGI_BYTES> bytes{};
    assert(encode(input, bytes));
    std::string hex;
    for (auto b : bytes) { hex += "0123456789abcdef"[b >> 4]; hex += "0123456789abcdef"[b & 15]; }
    // Same canonical fixture as viewflowd::hyprcapture_gpu_wire.
    assert(hex == "4843474900010058000000000000123400000000000056780000000000002334c004000000000000400a00000000000040890000000000004082c0000000000040790000000000004072c000000000000000000000000000");
    InputGeometry decoded{};
    assert(decode(bytes.data(), bytes.size(), decoded));
    assert(decoded.window == input.window && decoded.surface == input.surface && decoded.pid == input.pid);
    assert(decoded.content == input.content && decoded.surfaceExtent == input.surfaceExtent);
    for (std::size_t size = 0; size < bytes.size(); ++size) assert(!decode(bytes.data(), size, decoded));
    for (std::size_t at : {0, 4, 6, 80, 87}) {
        auto bad = bytes; bad[at] ^= 1; assert(!decode(bad.data(), bad.size(), decoded));
    }
    auto bad = input; bad.pid = std::uint64_t(INT32_MAX) + 1; assert(!encode(bad, bytes));
    bad = input; bad.surface = 0; assert(!encode(bad, bytes));
    bad = input; bad.content[2] = -1; assert(!encode(bad, bytes));
    bad = input; bad.surfaceExtent[1] = 0; assert(!encode(bad, bytes));
    bad = input; bad.content[0] = std::numeric_limits<double>::infinity(); assert(!encode(bad, bytes));
    bad = input; bad.content[0] = bad.content[2] = std::numeric_limits<double>::max(); assert(!encode(bad, bytes));
}
