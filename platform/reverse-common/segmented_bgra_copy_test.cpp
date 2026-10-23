#include "segmented_bgra_copy.hpp"
#include <cassert>
#include <cstdio>
#include <map>
int main() {
    using namespace viewflow::reverse;
    for (auto [w,h] : {std::pair{6144u,3456u}, {16384u,16384u}, {128u,1u}, {1024u,16384u}, {256u,16384u}, {6400u,3456u}}) {
        const auto plan = plan_segmented_bgra(w,h);
        std::uint64_t covered = 0;
        std::map<unsigned,unsigned> counts;
        for (const auto& c : plan) {
            assert(c.destination_offset % 512 == 0 && c.row_pitch % 256 == 0);
            assert(c.row_pitch == c.width * 4 && c.width && c.height);
            assert(c.source_x + c.width <= w && c.source_y + c.height <= h);
            assert(c.height == 1 || (c.source_x == 0 && c.width == w));
            assert(c.bytes == std::uint64_t(c.row_pitch) * c.height);
            assert(c.destination_offset + c.bytes <= (64ull << 20));
            assert((64ull << 20) * c.segment + c.destination_offset == covered);
            assert((std::uint64_t(c.source_y) * w + c.source_x) * 4 == covered);
            assert(++counts[c.segment] <= 3);
            covered += c.bytes;
        }
        assert(covered == std::uint64_t(w) * h * 4);
        std::printf("tight segmented plan %ux%u commands=%zu segments=%zu bytes=%llu passed\n",w,h,plan.size(),counts.size(),(unsigned long long)covered);
    }
    const auto six = plan_segmented_bgra(6144,3456);
    assert(six.size()==4);
    assert(six[0].height==2730 && six[1].width==4096);
    assert(six[2].source_x==4096 && six[2].width==2048 && six[2].destination_offset==0);
    assert(six[3].destination_offset==8192 && six[3].height==725);
    for (unsigned invalid : {0u,1u,6143u,16385u}) {
        bool rejected=false; try {(void)plan_segmented_bgra(invalid,3456);}catch(const std::invalid_argument&){rejected=true;}
        assert(rejected);
    }
}
