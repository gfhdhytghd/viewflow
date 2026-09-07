#include "annex_b.hpp"
#include <cassert>
using namespace viewflow::reverse;
int main() {
    const std::vector<std::uint8_t> sample{0,0,0,1,0x67,0x12,0,0,1,0x68,0x34,0,0};
    auto units = annex_b_units(sample);
    assert(units.size() == 2 && units[0].size() == 2 && units[1].size() == 2);
    const std::vector<std::uint8_t> avcc{0,0,0,2,0x67,0x12,0,0,0,2,0x68,0x34};
    const auto roundtrip = length_prefixed_to_annex_b(avcc, 4);
    assert(annex_b_units(roundtrip).size() == 2);
    for (const auto& invalid : std::vector<std::vector<std::uint8_t>>{{}, {0,0,1}, {7,0,0,1,0x67}, {0,0,1,0,0,1,2}}) {
        bool rejected = false;
        try { (void)annex_b_units(invalid); } catch (const std::runtime_error&) { rejected = true; }
        assert(rejected);
    }
    for (const auto& invalid : std::vector<std::vector<std::uint8_t>>{{0}, {0,0,0,0}, {0,0,0,5,1}}) {
        bool rejected = false;
        try { (void)length_prefixed_to_annex_b(invalid, 4); } catch (const std::runtime_error&) { rejected = true; }
        assert(rejected);
    }
}
