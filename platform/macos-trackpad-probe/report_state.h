#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// ABI 1: HID input report 1, five 6-byte contacts, contact count at byte 31.
// Contacts beyond count must be zero. Count includes explicit lift records.
namespace vf {
constexpr size_t report_size = 32;
constexpr uint64_t abi_version = 1;
inline bool valid_report(const uint8_t *p, size_t n) {
    if (!p || n != report_size || p[0] != 1 || p[31] > 5) return false;
    for (unsigned i = 0; i < 5; ++i) {
        const auto *c = p + 1 + 6 * i;
        if (i >= p[31]) {
            for (unsigned j = 0; j < 6; ++j) if (c[j]) return false;
        } else {
            if ((c[0] & ~3u) || (c[3] & 0x80) || (c[5] & 0x80)) return false;
            for (unsigned j = 0; j < i; ++j)
                if (c[1] == p[2 + 6 * j]) return false;
        }
    }
    return true;
}
struct ReportState {
    uint8_t last[report_size] = {1};
    bool active() const {
        for (unsigned i = 0; i < last[31]; ++i)
            if (last[1 + 6 * i] & 1) return true;
        return false;
    }
    template<class Submit> int apply(const uint8_t *p, size_t n, Submit submit) {
        if (!valid_report(p, n)) return -1;
        int result = submit(p, n);
        if (!result) memcpy(last, p, n);
        return result;
    }
    // Preserve IDs/positions for the explicit tip-up frame. On failure retain
    // state so cleanup can be retried instead of pretending release succeeded.
    template<class Submit> int release(Submit submit) {
        if (!active()) return 0;
        uint8_t lifted[report_size];
        memcpy(lifted, last, sizeof(lifted));
        for (unsigned i = 0; i < lifted[31]; ++i) lifted[1 + 6 * i] &= ~1u;
        int result = submit(lifted, sizeof(lifted));
        if (!result) { memset(last, 0, sizeof(last)); last[0] = 1; }
        return result;
    }
};
}
