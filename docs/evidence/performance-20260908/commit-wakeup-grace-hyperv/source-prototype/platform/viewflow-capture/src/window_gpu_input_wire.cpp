// SPDX-License-Identifier: GPL-3.0-only
#include "window_gpu_wire.hpp"
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstring>
#include <limits>

namespace viewflow_capture::gpuwire {
namespace {
bool fail(Error* out, Error error) { if (out) *out = error; return false; }
void put(std::uint8_t* p, std::uint64_t value) {
    for (int i = 7; i >= 0; --i) { p[i] = value & 255; value >>= 8; }
}
std::uint64_t get(const std::uint8_t* p) {
    std::uint64_t value = 0;
    for (int i = 0; i < 8; ++i) value = (value << 8) | p[i];
    return value;
}
bool valid(const InputGeometry& input, Error* error) {
    if (!input.window || !input.surface || !input.pid || input.pid > INT32_MAX)
        return fail(error, Error::ZeroLineage);
    for (double value : input.content) if (!std::isfinite(value)) return fail(error, Error::NonFinite);
    for (double value : input.surfaceExtent) if (!std::isfinite(value)) return fail(error, Error::NonFinite);
    if (!std::isfinite(input.content[0] + input.content[2]) || !std::isfinite(input.content[1] + input.content[3]))
        return fail(error, Error::NonFinite);
    if (input.content[2] <= 0 || input.content[3] <= 0 || input.surfaceExtent[0] <= 0 || input.surfaceExtent[1] <= 0)
        return fail(error, Error::Geometry);
    return true;
}
}
bool encode(const InputGeometry& input, std::array<std::uint8_t, HCGI_BYTES>& out, Error* error) {
    if (!valid(input, error)) return false;
    out.fill(0);
    const std::uint8_t prefix[]{'H','C','G','I',0,1,0,88};
    std::copy(std::begin(prefix), std::end(prefix), out.begin());
    put(out.data() + 8, input.window); put(out.data() + 16, input.surface); put(out.data() + 24, input.pid);
    for (std::size_t i = 0; i < 4; ++i) put(out.data() + 32 + i * 8, std::bit_cast<std::uint64_t>(input.content[i]));
    for (std::size_t i = 0; i < 2; ++i) put(out.data() + 64 + i * 8, std::bit_cast<std::uint64_t>(input.surfaceExtent[i]));
    return true;
}
bool decode(const std::uint8_t* bytes, std::size_t size, InputGeometry& out, Error* error) {
    if (size != HCGI_BYTES) return fail(error, Error::Length);
    if (std::memcmp(bytes, "HCGI", 4)) return fail(error, Error::Magic);
    if (bytes[4] != 0 || bytes[5] != 1) return fail(error, Error::Version);
    if (bytes[6] != 0 || bytes[7] != HCGI_BYTES) return fail(error, Error::HeaderLength);
    if (get(bytes + 80)) return fail(error, Error::Reserved);
    InputGeometry input{get(bytes + 8), get(bytes + 16), get(bytes + 24)};
    for (std::size_t i = 0; i < 4; ++i) input.content[i] = std::bit_cast<double>(get(bytes + 32 + i * 8));
    for (std::size_t i = 0; i < 2; ++i) input.surfaceExtent[i] = std::bit_cast<double>(get(bytes + 64 + i * 8));
    if (!valid(input, error)) return false;
    out = input;
    return true;
}
}
