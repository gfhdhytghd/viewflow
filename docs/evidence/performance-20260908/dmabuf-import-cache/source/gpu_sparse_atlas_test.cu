#include "gpu_sparse_atlas.cuh"
#include <cstdio>
#include <cstdlib>
#include <vector>
using namespace viewflow::gpu;
static void require(bool ok) { if(!ok) { std::fputs("sparse GPU assertion failed\n",stderr); std::abort(); } }
static void check(cudaError_t e) { if(e!=cudaSuccess) { std::fprintf(stderr,"%s\n",cudaGetErrorString(e)); std::abort(); } }
int main() {
  constexpr unsigned size=256;
  cudaStream_t stream{};check(cudaStreamCreate(&stream));
  std::vector<unsigned char> bottom(size*size*4),top(bottom.size());
  for(unsigned y=0;y<size;++y) for(unsigned x=0;x<size;++x) {
    const auto i=(y*size+x)*4;
    bottom[i+2]=255;bottom[i+3]=255;
    top[i]=255;
    top[i+3]=y<128 ? (x<128 ? 255:0) : (x<128 ? 128:255);
  }
  top[((255*size)+255)*4+3]=254; // one nonopaque pixel protects the whole boundary cell
  unsigned char *a{},*b{},*out{},*alpha{};size_t ap{},bp{},op{},alp{};
  check(cudaMallocPitch(&a,&ap,size*4,size));check(cudaMallocPitch(&b,&bp,size*4,size));
  check(cudaMallocPitch(&out,&op,size*4,384));check(cudaMallocPitch(&alpha,&alp,size,384));
  check(cudaMemcpy2DAsync(a,ap,bottom.data(),size*4,size*4,size,cudaMemcpyHostToDevice,stream));
  check(cudaMemcpy2DAsync(b,bp,top.data(),size*4,size*4,size,cudaMemcpyHostToDevice,stream));
  AtlasTile sources[]={{a,ap,256,256,0,0},{b,bp,256,256,0,0}};
  std::vector<SparseCell> cells;
  for(unsigned source=0;source<2;++source) for(unsigned y=0;y<size;y+=128) for(unsigned x=0;x<size;x+=128)
    cells.push_back({source,x,y,128,128,x,y,source+1,CellAlpha::Mixed,1});
  check(classifySparseCells(sources,2,cells,stream));
  require(cells[4].alpha==CellAlpha::Opaque && cells[5].alpha==CellAlpha::Empty &&
          cells[6].alpha==CellAlpha::Mixed && cells[7].alpha==CellAlpha::Mixed);
  auto plan=planSparseAtlas(cells,256,256,false);
  require(!plan.fits && plan.draws.size()==6 && plan.occludedPixels==16384 && plan.emptyPixels==16384);
  plan=planSparseAtlas(cells,256,384,false);
  check(composeSparseAtlas(sources,2,plan,{out,op,alpha,alp,256,384},stream));
  std::vector<unsigned char> pixels(256*384*4),mask(256*384);
  check(cudaMemcpy2DAsync(pixels.data(),256*4,out,op,256*4,384,cudaMemcpyDeviceToHost,stream));
  check(cudaMemcpy2DAsync(mask.data(),256,alpha,alp,256,384,cudaMemcpyDeviceToHost,stream));
  check(cudaStreamSynchronize(stream));
  for(const auto& draw:plan.draws) {
    const auto& p=draw.patch;
    for(unsigned y=0;y<p.height;++y) for(unsigned x=0;x<p.width;++x) {
      const auto dst=((p.y+y)*256+p.x+x)*4;
      const auto src=((p.sourceY+y)*256+p.sourceX+x)*4;
      const auto& original=p.source==0 ? bottom:top;
      for(unsigned c=0;c<4;++c) require(pixels[dst+c]==original[src+c]);
      require(mask[(p.y+y)*256+p.x+x]==original[src+3]);
    }
  }
  plan=planSparseAtlas(cells,256,256,true);
  require(plan.fits && plan.draws.size()==4 && plan.storedPixels==65536 && plan.occludedPixels==49152);
  check(composeSparseAtlas(sources,2,plan,{out,op,alpha,alp,256,256},stream));
  check(cudaMemcpy2DAsync(pixels.data(),256*4,out,op,256*4,256,cudaMemcpyDeviceToHost,stream));
  check(cudaStreamSynchronize(stream));
  for(const auto& draw:plan.draws) if(draw.layers.size()==2 && draw.patch.sourceX==0) {
    const auto i=(draw.patch.y*256+draw.patch.x)*4;
    require(pixels[i]==128 && pixels[i+1]==0 && pixels[i+2]==127 && pixels[i+3]==255);
  }
  // A reused atlas has no stale data when all windows become invisible.
  plan=planSparseAtlas({},256,256,false);
  check(composeSparseAtlas(sources,2,plan,{out,op,alpha,alp,256,256},stream));
  check(cudaMemcpy2DAsync(pixels.data(),256*4,out,op,256*4,256,cudaMemcpyDeviceToHost,stream));
  check(cudaStreamSynchronize(stream));
  for(size_t i=0;i<256*256*4;++i) require(pixels[i]==0);
  check(cudaFree(a));check(cudaFree(b));check(cudaFree(out));check(cudaFree(alpha));check(cudaStreamDestroy(stream));
  std::puts("sparse GPU alpha, opaque culling, transparent precomposition and reveal/clear passed");
}
