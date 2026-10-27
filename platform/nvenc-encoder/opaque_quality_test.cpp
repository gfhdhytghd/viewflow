#include "opaque_alpha.hpp"
#include <cassert>
int main() {
    using namespace viewflow::gpu;
    DmabufFrame frame{};
    frame.cropWidth=256;frame.cropHeight=128;
    ShadowSnapshot shadow{};
    shadow.cutoutLeft=64;shadow.cutoutTop=0;shadow.cutoutWidth=128;shadow.cutoutHeight=128;
    frame.shadow=shadow;
    std::vector<DmabufAtlasTile> tiles{{frame,0,0,0}};
    std::vector<SparseCell> cells{
        {0,0,0,64,128,0,0,1,CellAlpha::Mixed,1},
        {0,64,0,128,128,64,0,1,CellAlpha::Mixed,1},
        {0,128,0,128,128,128,0,1,CellAlpha::Mixed,1}};
    classifyOpaqueCells(tiles,cells);
    assert(cells[0].alpha==CellAlpha::Empty);
    assert(cells[1].alpha==CellAlpha::Opaque);
    assert(cells[2].alpha==CellAlpha::Mixed);
    OpaqueAlphaCache cache;
    const auto a=cache.get(256,128,tiles);
    assert((*a)[0]==0 && (*a)[64]==255 && (*a)[191]==255 && (*a)[192]==0);
    assert(a==cache.get(256,128,tiles));
}
