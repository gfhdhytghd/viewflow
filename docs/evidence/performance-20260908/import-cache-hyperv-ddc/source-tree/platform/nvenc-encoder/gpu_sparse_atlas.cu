#include "gpu_sparse_atlas.cuh"
#include <algorithm>
#include <set>
namespace viewflow::gpu {
namespace {
struct DeviceCell {
  const unsigned char* rgba;
  size_t pitch;
  unsigned x,y,width,height;
};
struct DeviceDraw { SparsePatch patch; unsigned first,count; };
__global__ void classify(const DeviceCell* cells,unsigned* flags) {
  const auto c=cells[blockIdx.x];
  unsigned bits=0;
  for(unsigned p=threadIdx.x;p<c.width*c.height;p+=blockDim.x) {
    const auto a=c.rgba[(c.y+p/c.width)*c.pitch+(c.x+p%c.width)*4+3];
    bits|=(a!=0 ? 1u:0u) | (a!=255 ? 2u:0u);
  }
  if(bits) atomicOr(flags+blockIdx.x,bits);
}
__global__ void compose(const DeviceDraw* draws,const DeviceCell* layers,AtlasOutput out) {
  const auto draw=draws[blockIdx.x];const auto p=draw.patch;
  for(unsigned pixel=threadIdx.x;pixel<p.width*p.height;pixel+=blockDim.x) {
    const unsigned x=pixel%p.width,y=pixel/p.width;
    unsigned char rgba[4]={0,0,0,0};
    for(unsigned i=0;i<draw.count;++i) {
      const auto layer=layers[draw.first+i];
      const auto* s=layer.rgba+(layer.y+y)*layer.pitch+(layer.x+x)*4;
      const float a=float(s[3])/255.f,b=float(rgba[3])/255.f;
      const float alpha=a+b*(1.f-a);
      // Prepared source and atlas are straight RGBA. Composite exactly once,
      // then let the receiver premultiply the shared atlas for Composition.
      for(int c=0;c<3;++c)
        rgba[c]=alpha>0.f ? static_cast<unsigned char>(fminf(255.f,
          (float(s[c])*a+float(rgba[c])*b*(1.f-a))/alpha+0.5f)):0;
      rgba[3]=static_cast<unsigned char>(alpha*255.f+0.5f);
    }
    auto* dest=out.rgba+(p.y+y)*out.rgbaPitch+(p.x+x)*4;
    for(int c=0;c<4;++c)dest[c]=rgba[c];
    out.alpha[(p.y+y)*out.alphaPitch+p.x+x]=rgba[3];
  }
}
bool validCell(const SparseCell& c,const AtlasTile* sources,size_t n) {
  return c.source<n && c.width && c.height && c.width<=128 && c.height<=128 &&
    sources[c.source].rgba && sources[c.source].width>0 && sources[c.source].height>0 &&
    sources[c.source].pitch>=size_t(sources[c.source].width)*4 &&
    uint64_t(c.sourceX)+c.width<=uint64_t(sources[c.source].width) &&
    uint64_t(c.sourceY)+c.height<=uint64_t(sources[c.source].height);
}
DeviceCell descriptor(const SparseCell& c,const AtlasTile* sources) {
  const auto& s=sources[c.source];return {s.rgba,s.pitch,c.sourceX,c.sourceY,c.width,c.height};
}
template<typename T> struct DeviceArray {
  T* data{};
  ~DeviceArray(){if(data)cudaFree(data);}
  cudaError_t allocate(size_t n){return cudaMalloc(&data,n*sizeof(T));}
  cudaError_t upload(const std::vector<T>& v,cudaStream_t stream) {
    auto error=allocate(v.size());
    return error==cudaSuccess ? cudaMemcpyAsync(data,v.data(),v.size()*sizeof(T),cudaMemcpyHostToDevice,stream):error;
  }
};
}
cudaError_t classifySparseCells(const AtlasTile* sources,size_t n,
                               std::vector<SparseCell>& cells,cudaStream_t stream) {
  if(n>4096 || (n&&!sources) || cells.size()>262144) return cudaErrorInvalidValue;
  std::vector<DeviceCell> host;host.reserve(cells.size());
  for(const auto& c:cells) {
    if(!validCell(c,sources,n))return cudaErrorInvalidValue;
    host.push_back(descriptor(c,sources));
  }
  if(cells.empty())return cudaSuccess;
  DeviceArray<DeviceCell> device;DeviceArray<unsigned> flags;
  auto error=device.upload(host,stream);
  if(error==cudaSuccess)error=flags.allocate(cells.size());
  if(error==cudaSuccess)error=cudaMemsetAsync(flags.data,0,cells.size()*sizeof(unsigned),stream);
  if(error==cudaSuccess) {
    // One block per cell, one launch for the entire scene.
    classify<<<unsigned(cells.size()),256,0,stream>>>(device.data,flags.data);
    error=cudaGetLastError();
  }
  std::vector<unsigned> summaries(cells.size());
  if(error==cudaSuccess)error=cudaMemcpyAsync(summaries.data(),flags.data,summaries.size()*sizeof(unsigned),cudaMemcpyDeviceToHost,stream);
  const auto completed=cudaStreamSynchronize(stream);
  if(error!=cudaSuccess)return error;
  if(completed!=cudaSuccess)return completed;
  for(size_t i=0;i<cells.size();++i)
    cells[i].alpha=!(summaries[i]&1) ? CellAlpha::Empty : !(summaries[i]&2) ? CellAlpha::Opaque : CellAlpha::Mixed;
  return cudaSuccess;
}
cudaError_t composeSparseAtlas(const AtlasTile* sources,size_t n,
                              const SparsePlan& plan,const AtlasOutput& out,cudaStream_t stream) {
  if(!plan.fits || n>4096 || (n&&!sources) || !out.rgba || !out.alpha ||
      out.width<=0 || out.height<=0 || out.rgbaPitch<size_t(out.width)*4 ||
      out.alphaPitch<size_t(out.width) || plan.draws.size()>32768)return cudaErrorInvalidValue;
  std::vector<DeviceDraw> draws;std::vector<DeviceCell> layers;
  draws.reserve(plan.draws.size());
  std::set<std::pair<unsigned,unsigned>> slots;
  for(const auto& draw:plan.draws) {
    const auto& p=draw.patch;
    if(draw.layers.empty() || uint64_t(p.x)+p.width>uint64_t(out.width) ||
        uint64_t(p.y)+p.height>uint64_t(out.height) || p.x%128 || p.y%128 ||
        !slots.emplace(p.x,p.y).second || layers.size()+draw.layers.size()>262144)return cudaErrorInvalidValue;
    draws.push_back({p,unsigned(layers.size()),unsigned(draw.layers.size())});
    for(const auto& c:draw.layers) {
      if(!validCell(c,sources,n) || c.width!=p.width || c.height!=p.height)return cudaErrorInvalidValue;
      layers.push_back(descriptor(c,sources));
    }
  }
  DeviceArray<DeviceDraw> deviceDraws;DeviceArray<DeviceCell> deviceLayers;
  auto error=cudaSuccess;
  if(!draws.empty())error=deviceDraws.upload(draws,stream);
  if(error==cudaSuccess && !layers.empty())error=deviceLayers.upload(layers,stream);
  if(error==cudaSuccess)error=cudaMemset2DAsync(out.rgba,out.rgbaPitch,0,size_t(out.width)*4,out.height,stream);
  if(error==cudaSuccess)error=cudaMemset2DAsync(out.alpha,out.alphaPitch,0,out.width,out.height,stream);
  if(error==cudaSuccess && !draws.empty()) {
    compose<<<unsigned(draws.size()),256,0,stream>>>(deviceDraws.data,deviceLayers.data,out);
    error=cudaGetLastError();
  }
  // Descriptor arrays and pageable upload storage live until the stream has
  // consumed them, including errors after a partial enqueue.
  const auto completed=cudaStreamSynchronize(stream);
  return error==cudaSuccess ? completed:error;
}
}
