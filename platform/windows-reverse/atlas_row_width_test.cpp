#include "atlas_row_width.hpp"
#include "atlas_capacity.hpp"
#include <cassert>
using namespace viewflow::reverse;
int main(){
    assert(atlas_row_width({{16384,16384,false}},16384,16384,16384,16384)==16384);
    assert(atlas_row_width({{9000,9000,false}},8192,4096,16384,16384)==16384);
    // Live two-window layout plus the normal-classified 720x160 transient.
    std::vector<AtlasExtent> windows{{2320,1374,false},{2714,1618,false}};
    assert(atlas_row_width(windows,5120,2304)==5120);
    windows.push_back({720,160,false});
    assert(atlas_row_width(windows,5120,2304)==5120);
    // A narrower animated transient and disappearance retain the same codec.
    windows.back().width=540;assert(atlas_row_width(windows,5120,2304)==5120);
    windows.pop_back();assert(atlas_row_width(windows,5120,2304)==5120);
    windows.push_back({1520,300,true});assert(atlas_row_width(windows,5120,2304)==5120);
    // Narrow packing must never drop tiles that fit in the old wider shelf.
    assert(atlas_row_width({{3000,2500,false},{3000,2500,false}},5120,4096)==8192);
    assert(atlas_row_width({{6000,1000,false}},5120,2304)==8192);
    assert(atlas_row_width({{2320,2000,false},{2714,2000,false},{720,500,false}},5120,2304)==8192);
    assert(atlas_row_width(windows,0,0)==8192);
    assert(atlas_row_width({{8192,4096,false}},8192,4096)==8192);
}
