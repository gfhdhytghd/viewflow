// Compare portable preparation against the unchanged NVIDIA kernels byte for
// byte, including shadows, seam repair and sparse precomposition.
#include "portable_rgba.hpp"
#include "gpu_rgba_prepare.cuh"
#include "gpu_shadow_repair.cuh"
#include "gpu_sparse_atlas.cuh"
#include <cuda_runtime_api.h>
#include <iostream>
#include <random>
using namespace viewflow::gpu;
namespace {
void check(cudaError_t value) {if(value!=cudaSuccess) throw std::runtime_error(cudaGetErrorString(value));}
struct Memory {
    unsigned char* data{};
    explicit Memory(size_t bytes){check(cudaMalloc(reinterpret_cast<void**>(&data),bytes));}
    ~Memory(){cudaFree(data);}
};
void run(bool flip,bool shadow,bool seam) {
    constexpr int w=128,h=128;
    std::mt19937 random(914);
    std::vector<unsigned char> pixels(w*h*4);
    for(auto& p:pixels) p=random()%256;
    if(seam) for(int x=0;x<w;++x) {
        pixels[(size_t(1)*w+x)*4+3]=255;
        pixels[(size_t(2)*w+x)*4+3]=0;
        pixels[(size_t(3)*w+x)*4+3]=255;
    }
    DmabufAtlasTile input;
    input.frame.cropWidth=w;input.frame.cropHeight=h;input.frame.flipVertical=flip;
    if(shadow) input.frame.shadow=ShadowSnapshot{-4,-2,124,128,16,16,88,88,24,12,16,2,3,20,30,10,200,false};
    auto cpu=prepareCpuTile(pixels,input);
    Memory source(pixels.size()),rgba(pixels.size()),alpha(w*h);
    check(cudaMemcpy(source.data,pixels.data(),pixels.size(),cudaMemcpyHostToDevice));
    check(prepareRgba({source.data,w*4,w,h,0,0,w,h,flip,rgba.data,w*4,alpha.data,w},nullptr));
    if(shadow) check(repairShadow({rgba.data,w*4,alpha.data,w,w,h,*input.frame.shadow},nullptr));
    check(cudaDeviceSynchronize());
    std::vector<unsigned char> actual(pixels.size()),actualAlpha(w*h);
    check(cudaMemcpy(actual.data(),rgba.data,actual.size(),cudaMemcpyDeviceToHost));
    check(cudaMemcpy(actualAlpha.data(),alpha.data,actualAlpha.size(),cudaMemcpyDeviceToHost));
    if(actual!=cpu.rgba) throw std::runtime_error("portable RGBA differs from CUDA oracle");
    for(size_t i=0;i<actualAlpha.size();++i) if(actualAlpha[i]!=cpu.rgba[i*4+3]) throw std::runtime_error("portable alpha differs from CUDA oracle");
    std::vector<CpuTile> cpus={cpu,cpu};
    std::vector<AtlasTile> gpus={{rgba.data,w*4,w,h,0,0},{rgba.data,w*4,w,h,128,0}};
    std::vector<SparseCell> cells={{0,0,0,w,h,0,0,0,CellAlpha::Mixed,0},{1,0,0,w,h,0,0,1,CellAlpha::Mixed,0}};
    auto gpuCells=cells;classifyCpuCells(cpus,cells);check(classifySparseCells(gpus.data(),gpus.size(),gpuCells,nullptr));
    for(size_t i=0;i<cells.size();++i) if(cells[i].alpha!=gpuCells[i].alpha) throw std::runtime_error("portable cell classification mismatch");
    auto plan=planSparseAtlas(cells,256,128,true);
    std::vector<unsigned char> composed;composeCpuSparse(cpus,plan,256,128,composed);
    Memory atlas(composed.size()),atlasAlpha(256*128);
    check(composeSparseAtlas(gpus.data(),gpus.size(),plan,{atlas.data,256*4,atlasAlpha.data,256,256,128},nullptr));
    actual.resize(composed.size());check(cudaMemcpy(actual.data(),atlas.data,actual.size(),cudaMemcpyDeviceToHost));
    if(actual!=composed) throw std::runtime_error("portable sparse precomposition differs from CUDA oracle");
}
}
int main() {
    try {
        for(bool flip:{false,true}) for(bool shadow:{false,true}) for(bool seam:{false,true}) run(flip,shadow,seam);
        std::cout<<"PASS portable/CUDA byte equality: flip, alpha, seam, shadow, sparse classification and precomposition (8 cases)\n";
    } catch(const std::exception& error) {std::cerr<<error.what()<<'\n';return 1;}
}
