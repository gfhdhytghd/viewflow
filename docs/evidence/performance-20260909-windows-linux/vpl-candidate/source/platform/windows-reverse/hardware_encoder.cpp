#include "hardware_encoder.hpp"
#include "mft_encoder.hpp"
#include "vpl_encoder.hpp"
#include <cstdlib>
#include <cstring>
namespace viewflow::reverse {
struct HardwareEncoder::Impl { std::unique_ptr<MediaFoundationEncoder> mft;std::unique_ptr<VplEncoder> vpl; };
HardwareEncoder::HardwareEncoder():impl_(std::make_unique<Impl>()){}
HardwareEncoder::~HardwareEncoder()=default;
HRESULT HardwareEncoder::start(ID3D11Device* d,unsigned w,unsigned h,unsigned fps,unsigned codec){
 if(impl_->vpl||impl_->mft)return E_UNEXPECTED;
 const auto setting=std::getenv("VIEWFLOW_REVERSE_ENCODER");
 if(codec==2 && setting && std::strcmp(setting,"vpl")==0){impl_->vpl=std::make_unique<VplEncoder>();return impl_->vpl->start(d,w,h,fps,codec);}
 impl_->mft=std::make_unique<MediaFoundationEncoder>();return impl_->mft->start(d,w,h,fps,codec);
}
HRESULT HardwareEncoder::can_submit(){return impl_->vpl?impl_->vpl->can_submit():impl_->mft?impl_->mft->can_submit():E_UNEXPECTED;}
HRESULT HardwareEncoder::submit(ID3D11Texture2D* t,std::int64_t pts,bool key){return impl_->vpl?impl_->vpl->submit(t,pts,key):impl_->mft?impl_->mft->submit(t,pts,key):E_UNEXPECTED;}
HRESULT HardwareEncoder::poll(std::vector<EncodedFrame>& frames){return impl_->vpl?impl_->vpl->poll(frames):impl_->mft?impl_->mft->poll(frames):E_UNEXPECTED;}
}
