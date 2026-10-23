#include "atlas_capacity.hpp"
#include <cassert>
int main(){
    viewflow::reverse::AtlasCapacity raw;
    assert(raw.select_shared(6144,3456,0,false,16384,16384)==std::make_pair(6144u,3456u));
    assert(raw.select_shared(6199,3511,1,true,16384,16384)==std::make_pair(6199u,3511u));
    assert(raw.select_shared(6144,3456,2,false,16384,16384)==std::make_pair(6199u,3511u));
    assert(raw.select_shared(6144,3456,3002,false,16384,16384)==std::make_pair(6144u,3456u));
    viewflow::reverse::AtlasCapacity popup;
    assert(popup.select_shared(104,82,0,false,16384,16384)==std::make_pair(104u,82u));

    // Segmented DMA aligns only the atlas width; actual tile/window dimensions
    // stay outside AtlasCapacity and height must not acquire codec padding.
    for(const auto [requested,expected]:{std::pair{3824u,3840u},{6144u,6144u},{16383u,16384u},{16384u,16384u},{1u,128u}}){
        viewflow::reverse::AtlasCapacity segmented;
        const auto extent=segmented.select(requested,3456,0,false,16384,16384,128,1);
        assert(extent==std::make_pair(expected,3456u));
        assert(extent.first>=requested && extent.first-requested<=127 && extent.first%128==0);
    }
    viewflow::reverse::AtlasCapacity segmented_popup;
    assert(segmented_popup.select(104,82,0,false,16384,16384,128,1)==std::make_pair(128u,82u));
    viewflow::reverse::AtlasCapacity segmented_max;
    assert(segmented_max.select(16384,16384,0,false,16384,16384,128,1)==std::make_pair(16384u,16384u));

    viewflow::reverse::AtlasCapacity large;
    assert(large.select(16384,16384,0,false,16384,16384)==std::make_pair(16384u,16384u));
    assert(large.select(1000,800,1,false,16384,16384)==std::make_pair(16384u,16384u));
    assert(large.select(1000,800,3001,false,16384,16384)==std::make_pair(1024u,1024u));
    viewflow::reverse::AtlasCapacity c;
    assert(c.select(4544,2176,0,false)==std::make_pair(4608u,2304u));
    // Candidate width animation fits the reserved bottom band without codec churn.
    for(unsigned width:{1198u,1314u,1290u,1412u,1520u})
        assert(c.select(std::max(4544u,width),2176,100,true)==std::make_pair(4608u,2304u));
    assert(c.select(5100,2400,200,true)==std::make_pair(5120u,2560u));
    assert(c.select(4544,2176,300,false)==std::make_pair(5120u,2560u));
    assert(c.select(4544,2176,3299,false)==std::make_pair(5120u,2560u));
    assert(c.select(4544,2176,3300,false)==std::make_pair(4608u,2304u));
}
