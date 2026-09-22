#include "portable_rgba.hpp"
#include <cassert>
#include <iostream>
using namespace viewflow::gpu;
int main() {
    // Exhaust all alpha/channel pairs. Transparency must not leak hidden RGB.
    DmabufAtlasTile descriptor;descriptor.frame.cropWidth=65536;descriptor.frame.cropHeight=1;
    std::vector<unsigned char> pixels(65536*4);
    for(unsigned a=0;a<256;++a) for(unsigned c=0;c<256;++c) {
        auto i=(a*256+c)*4;pixels[i]=pixels[i+1]=pixels[i+2]=c;pixels[i+3]=a;
    }
    auto prepared=prepareCpuTile(pixels,descriptor);
    for(unsigned a=0;a<256;++a) for(unsigned c=0;c<256;++c) {
        auto i=(a*256+c)*4;
        assert(prepared.rgba[i]==(a?std::min(255u,(c*255+a/2)/a):0));
        assert(prepared.rgba[i+3]==a);
    }
    descriptor.frame.cropWidth=32;descriptor.frame.cropHeight=5;
    pixels.assign(32*5*4,255);
    for(int x=0;x<32;++x) {pixels[(32+x)*4+3]=0;pixels[(3*32+x)*4+3]=0;}
    prepared=prepareCpuTile(pixels,descriptor);
    assert(prepared.rgba[(32+12)*4+3]==255); // first seam repaired
    assert(prepared.rgba[(3*32+12)*4+3]==0); // second retained
    descriptor.frame.flipVertical=true;
    pixels.assign(32*5*4,128);pixels[3]=255;
    prepared=prepareCpuTile(pixels,descriptor);
    assert(prepared.rgba[(4*32)*4+3]==255 && prepared.rgba[3]==128);
    // A clipped cell must classify only its in-bounds visible area.
    CpuTile back{128,128,0,0,std::vector<unsigned char>(128*128*4,255)};
    CpuTile front{128,128,128,0,std::vector<unsigned char>(128*128*4,0)};
    for(int y=0;y<128;++y) for(int x=0;x<64;++x) {
        auto i=(y*128+x)*4;front.rgba[i]=255;front.rgba[i+3]=128;
    }
    std::vector<CpuTile> tiles={back,front};
    std::vector<SparseCell> cells={{0,0,0,128,128,0,0,0,CellAlpha::Mixed,0},
                                 {1,0,0,128,128,0,0,1,CellAlpha::Mixed,0}};
    classifyCpuCells(tiles,cells);
    assert(cells[0].alpha==CellAlpha::Opaque && cells[1].alpha==CellAlpha::Mixed);
    auto plan=planSparseAtlas(cells,256,128,true);
    assert(plan.draws.size()==1 && plan.draws[0].layers.size()==2);
    std::vector<unsigned char> composed;
    composeCpuSparse(tiles,plan,256,128,composed);
    assert(composed[0]==255 && composed[1]==127 && composed[3]==255);
    assert(composed[100*4]==255 && composed[100*4+1]==255);
    assert(composed[200*4+3]==0);
    cells={cells[1]};assert(clipSparseCell(cells[0],64,0,64,128));classifyCpuCells(tiles,cells);
    assert(cells[0].alpha==CellAlpha::Empty);
    std::cout<<"PASS portable alpha, flip, seam, sparse clipping and straight-alpha composition\n";
}
