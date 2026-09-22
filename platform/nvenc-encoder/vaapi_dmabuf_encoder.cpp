#include "vaapi_dmabuf_encoder.hpp"
#include "portable_rgba.hpp"
#include "portable_dmabuf_import.hpp"
#include "../linux-media/egl_device.hpp"
#include "../linux-media/vaapi_encoder.hpp"
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <poll.h>
#include <cerrno>
#include <climits>
#include <chrono>
#include <thread>

namespace viewflow::gpu {
namespace {
int64_t nowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
bool waitFence(int fd,int64_t deadline) {
    for(;;) {
        auto remaining=deadline-nowNs();
        if(remaining<=0) return false;
        pollfd item{fd,POLLIN,0};
        auto timeout=std::min<int64_t>((remaining+999999)/1000000,INT_MAX);
        const int result=poll(&item,1,int(timeout));
        if(result<0 && errno==EINTR) continue;
        if(result<0 || (item.revents&(POLLERR|POLLNVAL|POLLHUP))) throw std::runtime_error("capture DMA-BUF fence wait failed");
        if(result && (item.revents&POLLIN)) return true;
    }
}

}
struct VaapiDmabufEncoder::Impl {
    GpuDmabufEncoderConfig config;
    media::EglDevice egl;
    media::VaapiEncoder encoder;
    std::thread::id owner=std::this_thread::get_id();
    std::vector<SparsePatch> lastSparsePatches;
    bool recoveryIdr=true;
    std::shared_ptr<const std::vector<unsigned char>> lastAlpha;
    Impl(const GpuDmabufEncoderConfig& c,const std::string& node):config(c),egl(node),encoder(c.outputWidth,c.outputHeight,c.colorCodec,node) {}
};
VaapiDmabufEncoder::VaapiDmabufEncoder(const GpuDmabufEncoderConfig& c,const std::string& node):impl_(std::make_unique<Impl>(c,node)) {}
VaapiDmabufEncoder::~VaapiDmabufEncoder()=default;
bool VaapiDmabufEncoder::encodeAtlas(const std::vector<DmabufAtlasTile>& inputs,FrameMetadata metadata,
    bool forceIdr,int64_t deadline,EncodedDmabufFrame& output,std::string* error,EncodeDisposition* disposition,const SparseOptions* sparse) {
    output={};
    if(disposition) *disposition=EncodeDisposition::Failed;
    try {
        auto& s=*impl_; const int width=s.config.outputWidth,height=s.config.outputHeight;
        if(s.owner!=std::this_thread::get_id()) throw std::runtime_error("VA-API encoder used from another thread");
        if(inputs.size()>4096 || !metadata.frameId || !metadata.geometryEpoch || !metadata.captureTimestampNs || metadata.captureTimestampNs>uint64_t(INT64_MAX))
            throw std::invalid_argument("invalid atlas metadata or tile count");
        if(sparse && (sparse->sources.size()!=inputs.size() || sparse->maxWidth<unsigned(width) || sparse->maxHeight<unsigned(height) ||
            sparse->maxWidth>8192 || sparse->maxHeight>4096)) throw std::invalid_argument("invalid sparse capacity");
        for(size_t i=0;i<inputs.size();++i) {
            const auto& t=inputs[i]; const auto& f=t.frame;
            deadline=std::min(deadline,t.absoluteMonotonicDeadlineNs);
            if(f.dmaBufFd<0 || f.nativeFenceFd<0 || f.fourcc!=DRM_FORMAT_ABGR8888 || !f.imageWidth || !f.imageHeight ||
               f.imageWidth>INT_MAX || f.imageHeight>INT_MAX || f.stride>INT_MAX || f.offset>INT_MAX || f.stride<uint64_t(f.imageWidth)*4 ||
               f.cropX<0 || f.cropY<0 || f.cropWidth<=0 || f.cropHeight<=0 || f.cropWidth>width || f.cropHeight>height ||
               f.cropX>int(f.imageWidth)-f.cropWidth || f.cropY>int(f.imageHeight)-f.cropHeight ||
               !f.metadata.frameId || !f.metadata.geometryEpoch || !f.metadata.captureTimestampNs || f.metadata.captureTimestampNs>uint64_t(INT64_MAX))
                throw std::invalid_argument("invalid portable DMA-BUF crop");
            if(!sparse || sparse->stablePlacement) {
                if(t.x<0 || t.y<0 || t.x>width-f.cropWidth || t.y>height-f.cropHeight) throw std::invalid_argument("atlas tile outside canvas");
                for(size_t j=0;j<i;++j) {
                    const auto& o=inputs[j];
                    if(t.x<o.x+o.frame.cropWidth && o.x<t.x+f.cropWidth && t.y<o.y+o.frame.cropHeight && o.y<t.y+f.cropHeight)
                        throw std::invalid_argument("overlapping atlas tiles");
                }
            }
        }
        auto expired=[&] {
            if(disposition) *disposition=EncodeDisposition::ExpiredBeforeSubmission;
            if(error) *error="VA-API frame retired before submission; capture reads completed";
            return false;
        };
        if(nowNs()>=deadline) return expired();
        s.egl.makeCurrent();
        std::vector<CpuTile> prepared;
        for(const auto& tile:inputs) {
            if(!waitFence(tile.frame.nativeFenceFd,deadline)) return expired();
            prepared.push_back(readPortableDmabuf(s.egl.display(),tile));
            if(nowNs()>=deadline) return expired();
        }
        std::vector<unsigned char> rgba(size_t(width)*height*4,0);
        std::optional<SparseResult> sparseResult;
        forceIdr|=s.recoveryIdr;
        if(sparse) {
    std::vector<SparseCell> cells;
    uint64_t clippedPixels = 0;
    auto floorCell = [](int64_t x) { return x / 128 - (x % 128 < 0); };
    for (uint32_t i = 0; i < prepared.size(); ++i) {
      const auto& tile = prepared[i];
      const auto& scene = sparse->sources[i];
      if (scene.x < INT64_MIN + 8192 || scene.x > INT64_MAX - 8192 ||
          scene.y < INT64_MIN + 8192 || scene.y > INT64_MAX - 8192) {
        throw std::invalid_argument("sparse scene coordinate overflow");
      }
      for (uint32_t sy = 0; sy < uint32_t(tile.height);) {
        const auto y = scene.y + sy;
        const uint32_t h = uint32_t(std::min<int64_t>(tile.height - sy, (floorCell(y)+1)*128-y));
        for (uint32_t sx = 0; sx < uint32_t(tile.width);) {
          const auto x = scene.x + sx;
          const uint32_t w = uint32_t(std::min<int64_t>(tile.width - sx, (floorCell(x)+1)*128-x));
          SparseCell cell{i,sx,sy,w,h,x,y,scene.z,CellAlpha::Mixed,scene.grid};
          if (!scene.clipEnabled || clipSparseCell(cell,scene.clipX,scene.clipY,scene.clipWidth,scene.clipHeight)) {
            cells.push_back(cell);
            clippedPixels += uint64_t(w)*h-uint64_t(cell.width)*cell.height;
          } else clippedPixels += uint64_t(w)*h;
          sx += w;
          if (cells.size() > 262144) { throw std::invalid_argument("sparse cell resource limit"); }
        }
        sy += h;
      }
    }
    classifyCpuCells(prepared,cells);
    auto plan = planSparseAtlas(cells, width, height, sparse->prerender, 256);
    if (sparse->stablePlacement) {
      std::vector<std::pair<uint32_t, uint32_t>> origins;
      for (const auto& tile : prepared)
        origins.emplace_back(uint32_t(tile.x), uint32_t(tile.y));
      placeSparseAtlasStable(plan, origins, width, height);
      // Input validation already proves every reserved source fits the canvas.
      if (!plan.fits) { throw std::invalid_argument("stable sparse placement outside canvas"); }
    }
    sparseResult = SparseResult{{}, plan.requiredWidth, plan.requiredHeight, plan.inputPixels + clippedPixels,
                               plan.storedPixels, plan.occludedPixels + clippedPixels, plan.emptyPixels, 0};
    if (!plan.fits) {
      uint32_t w = width, h = height;
      // Growth happens after source reads have finished and leases are released.
      // Prefer the smallest doubling candidate that accommodates the live cells.
      while (uint64_t(w/128)*(h/128) < plan.draws.size() &&
             (w < sparse->maxWidth || h < sparse->maxHeight)) {
        if (w < sparse->maxWidth && (w <= h*2 || h == sparse->maxHeight))
          w = std::min(sparse->maxWidth, w*2);
        else h = std::min(sparse->maxHeight, h*2);
      }
      if (w != uint32_t(width) || h != uint32_t(height)) {
        sparseResult->requiredWidth = w;
        sparseResult->requiredHeight = h;
        output.sparse = std::move(sparseResult);
        if (disposition) *disposition = EncodeDisposition::NeedsCanvas;
        return false;
      }
      // At the negotiated cap retain topmost visible cells first. A missing
      // patch is transparent residency, never removal of native window/input.
      const size_t capacity = size_t(w/128)*(h/128);
      std::stable_sort(plan.draws.begin(), plan.draws.end(), [](const auto& a, const auto& b) {
        return a.layers.back().z > b.layers.back().z;
      });
      for (size_t i=capacity; i<plan.draws.size(); ++i)
        sparseResult->omittedPixels += uint64_t(plan.draws[i].patch.width)*plan.draws[i].patch.height;
      plan.draws.resize(capacity);
      std::sort(plan.draws.begin(), plan.draws.end(), [](const auto& a, const auto& b) {
        return std::tie(a.patch.source,a.patch.sourceY,a.patch.sourceX) <
               std::tie(b.patch.source,b.patch.sourceY,b.patch.sourceX);
      });
      for(size_t i=0;i<plan.draws.size();++i) {
        plan.draws[i].patch.x=uint32_t(i%(w/128))*128;
        plan.draws[i].patch.y=uint32_t(i/(w/128))*128;
      }
      plan.fits=true;
      sparseResult->storedPixels -= sparseResult->omittedPixels;
    }
    sparseResult->requiredWidth = width;
    sparseResult->requiredHeight = height;
    for(const auto& draw:plan.draws) sparseResult->patches.push_back(draw.patch);
    const auto same = [](const SparsePatch& a,const SparsePatch& b) {
      return std::tie(a.source,a.sourceX,a.sourceY,a.x,a.y,a.width,a.height) ==
             std::tie(b.source,b.sourceX,b.sourceY,b.x,b.y,b.width,b.height);
    };
    forceIdr = forceIdr || sparseResult->patches.size()!=s.lastSparsePatches.size() ||
      !std::equal(sparseResult->patches.begin(), sparseResult->patches.end(), s.lastSparsePatches.begin(), same);
            composeCpuSparse(prepared,plan,width,height,rgba);
        } else {
            for(const auto& tile:prepared) for(int y=0;y<tile.height;++y)
                std::memcpy(rgba.data()+(size_t(tile.y+y)*width+tile.x)*4,
                    tile.rgba.data()+size_t(y)*tile.width*4,size_t(tile.width)*4);
        }
        if(nowNs()>=deadline) return expired();
        // A missed performance deadline after submission never invalidates a
        // session: finish this packet, preserving its codec and alpha reference.
        bool keyframe=false;
        auto bytes=s.encoder.encode(rgba,forceIdr,keyframe);
        if(bytes.size()>s.config.maxAccessUnitBytes) throw std::runtime_error("VA-API access unit exceeds negotiated bound");
        output.colorAnnexB=std::move(bytes);output.idr=keyframe;output.metadata=metadata;
        output.rawAlpha.resize(size_t(width)*height);
        for(size_t i=0;i<output.rawAlpha.size();++i) output.rawAlpha[i]=rgba[i*4+3];
        const char* reuse=std::getenv("VIEWFLOW_GPU_ALPHA_REUSE");
        if(!reuse || std::strcmp(reuse,"0")!=0) {
            if(s.lastAlpha && *s.lastAlpha==output.rawAlpha) output.sharedAlpha=s.lastAlpha;
            else output.sharedAlpha=std::make_shared<const std::vector<unsigned char>>(std::move(output.rawAlpha));
            output.rawAlpha.clear();s.lastAlpha=output.sharedAlpha;
        }
        output.sparse=std::move(sparseResult);
        if(output.sparse) s.lastSparsePatches=output.sparse->patches;
        s.recoveryIdr=false;
        if(disposition) *disposition=EncodeDisposition::Encoded;
        return true;
    } catch(const std::exception& failure) {
        if(error) *error=failure.what();
        impl_->recoveryIdr=true;
        return false;
    }
}
}
