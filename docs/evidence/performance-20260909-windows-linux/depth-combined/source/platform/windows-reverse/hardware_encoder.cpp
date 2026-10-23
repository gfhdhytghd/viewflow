#include "hardware_encoder.hpp"
#include "mft_encoder.hpp"
#include "vpl_encoder.hpp"
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <wrl/client.h>
#include <dxgi.h>
namespace viewflow::reverse {
struct HardwareEncoder::Impl { std::unique_ptr<MediaFoundationEncoder> mft;std::unique_ptr<VplEncoder> vpl; };
HardwareEncoder::HardwareEncoder():impl_(std::make_unique<Impl>()){}
HardwareEncoder::~HardwareEncoder()=default;
HRESULT HardwareEncoder::start(ID3D11Device* d,unsigned w,unsigned h,unsigned fps,unsigned codec){
 if(impl_->vpl||impl_->mft)return E_UNEXPECTED;
 if(!d)return E_INVALIDARG;
 const auto setting=std::getenv("VIEWFLOW_REVERSE_ENCODER");
 const bool force_vpl=setting && std::strcmp(setting,"vpl")==0;
 const bool force_mft=setting && std::strcmp(setting,"mft")==0;
 Microsoft::WRL::ComPtr<IDXGIDevice> dxgi;Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;DXGI_ADAPTER_DESC desc{};
 if(SUCCEEDED(d->QueryInterface(IID_PPV_ARGS(&dxgi))) && SUCCEEDED(dxgi->GetAdapter(&adapter)))adapter->GetDesc(&desc);
 if(codec==2 && (force_vpl || (!force_mft && desc.VendorId==0x8086))){
  impl_->vpl=std::make_unique<VplEncoder>();const auto result=impl_->vpl->start(d,w,h,fps,codec);
  if(SUCCEEDED(result)){std::fprintf(stderr,"encoder_backend selected=vpl vendor=%u forced=%u\n",desc.VendorId,unsigned(force_vpl));return result;}
  std::fprintf(stderr,"encoder_backend vpl_start=%08lx fallback=%u\n",static_cast<unsigned long>(result),unsigned(!force_vpl));
  if(force_vpl)return result;
  impl_->vpl.reset();
 }
 std::fprintf(stderr,"encoder_backend selected=mft vendor=%u forced=%u\n",desc.VendorId,unsigned(force_mft));
 impl_->mft=std::make_unique<MediaFoundationEncoder>();return impl_->mft->start(d,w,h,fps,codec);
}
HRESULT HardwareEncoder::can_submit(){return impl_->vpl?impl_->vpl->can_submit():impl_->mft?impl_->mft->can_submit():E_UNEXPECTED;}
HRESULT HardwareEncoder::submit(ID3D11Texture2D* t,std::int64_t pts,bool key){return impl_->vpl?impl_->vpl->submit(t,pts,key):impl_->mft?impl_->mft->submit(t,pts,key):E_UNEXPECTED;}
HRESULT HardwareEncoder::request_output(){return impl_->vpl?impl_->vpl->request_output():impl_->mft?S_OK:E_UNEXPECTED;}
HRESULT HardwareEncoder::poll(std::vector<EncodedFrame>& frames){return impl_->vpl?impl_->vpl->poll(frames):impl_->mft?impl_->mft->poll(frames):E_UNEXPECTED;}
}
