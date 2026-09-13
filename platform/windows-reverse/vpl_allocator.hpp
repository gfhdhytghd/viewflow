#pragma once
#include <d3d11.h>
#include <wrl/client.h>
#include <vpl/mfxvideo.h>
#include <cstdio>
#include <vector>
#include <unordered_map>
#include <memory>
using Microsoft::WRL::ComPtr;
// Video-memory inputs stay GPU-resident. Only an encoder-requested P8 staging
// buffer supports CPU locking; unsupported allocation formats return an error.
struct VplMemory { ComPtr<ID3D11Resource> resource; bool buffer{}; };
struct VplBlock { std::vector<VplMemory> resources; std::vector<mfxMemId> ids; };
struct VplAllocator {
 ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
 std::unordered_map<mfxMemId*,std::unique_ptr<VplBlock>> blocks;
 mfxFrameAllocator callbacks{};
 VplAllocator(){callbacks.pthis=this;callbacks.Alloc=alloc;callbacks.Free=free;callbacks.Lock=lock;callbacks.Unlock=unlock;callbacks.GetHDL=handle;}
 static mfxStatus MFX_CDECL alloc(mfxHDL self,mfxFrameAllocRequest* req,mfxFrameAllocResponse* out){
  if(!self||!req||!out)return MFX_ERR_NULL_PTR;auto& a=*static_cast<VplAllocator*>(self);
  std::fprintf(stderr,"alloc fourcc=%u type=%u width=%u height=%u min=%u suggested=%u\n",req->Info.FourCC,req->Type,req->Info.Width,req->Info.Height,req->NumFrameMin,req->NumFrameSuggested);
  try{
   auto block=std::make_unique<VplBlock>();const auto count=req->NumFrameSuggested;if(!count)return MFX_ERR_MEMORY_ALLOC;block->resources.resize(count);block->ids.resize(count);
   for(unsigned j=0;j<count;++j){auto& memory=block->resources[j];HRESULT hr{};
    if(req->Info.FourCC==MFX_FOURCC_P8){D3D11_BUFFER_DESC d{};d.ByteWidth=unsigned(req->Info.Width)*req->Info.Height;d.Usage=D3D11_USAGE_STAGING;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;ComPtr<ID3D11Buffer> buffer;hr=a.device->CreateBuffer(&d,nullptr,&buffer);memory.resource=buffer;memory.buffer=true;}
    else if(req->Info.FourCC==MFX_FOURCC_NV12){D3D11_TEXTURE2D_DESC d{};d.Width=req->Info.Width;d.Height=req->Info.Height;d.ArraySize=d.MipLevels=d.SampleDesc.Count=1;d.Format=DXGI_FORMAT_NV12;d.MiscFlags=D3D11_RESOURCE_MISC_SHARED;d.BindFlags=D3D11_BIND_DECODER;if((req->Type&MFX_MEMTYPE_VIDEO_MEMORY_ENCODER_TARGET)&&(req->Type&MFX_MEMTYPE_INTERNAL_FRAME))d.BindFlags|=D3D11_BIND_VIDEO_ENCODER;ComPtr<ID3D11Texture2D> texture;hr=a.device->CreateTexture2D(&d,nullptr,&texture);memory.resource=texture;}
    else return MFX_ERR_UNSUPPORTED;
    if(FAILED(hr)){std::fprintf(stderr,"alloc texture hr=%08lx\n",(unsigned long)hr);return MFX_ERR_MEMORY_ALLOC;}block->ids[j]=&memory;
   }
   out->mids=block->ids.data();out->NumFrameActual=count;a.blocks.emplace(out->mids,std::move(block));return MFX_ERR_NONE;
  }catch(...){return MFX_ERR_MEMORY_ALLOC;}
 }
 static mfxStatus MFX_CDECL free(mfxHDL self,mfxFrameAllocResponse* response){if(!self||!response)return MFX_ERR_NULL_PTR;auto& a=*static_cast<VplAllocator*>(self);a.blocks.erase(response->mids);response->mids=nullptr;response->NumFrameActual=0;return MFX_ERR_NONE;}
 static mfxStatus MFX_CDECL handle(mfxHDL,mfxMemId id,mfxHDL* h){if(!id||!h)return MFX_ERR_NULL_PTR;auto memory=static_cast<VplMemory*>(id);auto pair=reinterpret_cast<mfxHDLPair*>(h);pair->first=memory->resource.Get();pair->second=nullptr;return MFX_ERR_NONE;}
 static mfxStatus MFX_CDECL lock(mfxHDL self,mfxMemId id,mfxFrameData* data){if(!self||!id||!data)return MFX_ERR_NULL_PTR;auto& a=*static_cast<VplAllocator*>(self);auto memory=static_cast<VplMemory*>(id);if(!memory->buffer)return MFX_ERR_UNSUPPORTED;D3D11_MAPPED_SUBRESOURCE mapped{};if(FAILED(a.context->Map(memory->resource.Get(),0,D3D11_MAP_READ,0,&mapped)))return MFX_ERR_LOCK_MEMORY;data->Y=static_cast<mfxU8*>(mapped.pData);return MFX_ERR_NONE;}
 static mfxStatus MFX_CDECL unlock(mfxHDL self,mfxMemId id,mfxFrameData* data){if(!self||!id)return MFX_ERR_NULL_PTR;auto& a=*static_cast<VplAllocator*>(self);auto memory=static_cast<VplMemory*>(id);if(!memory->buffer)return MFX_ERR_UNSUPPORTED;a.context->Unmap(memory->resource.Get(),0);if(data)data->Y=nullptr;return MFX_ERR_NONE;}
};
