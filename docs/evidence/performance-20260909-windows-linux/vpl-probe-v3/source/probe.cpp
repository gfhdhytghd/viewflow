#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11_4.h>
#include <wrl/client.h>
#include <vpl/mfxdispatcher.h>
#include <vpl/mfxvideo.h>
#include <cstdio>
#include <vector>
#include <stdexcept>
#include <chrono>
#include <cstdlib>
using Microsoft::WRL::ComPtr;
#define API(name) decltype(&name) p##name{};
#define APIS(F) F(MFXLoad) F(MFXUnload) F(MFXCreateConfig) F(MFXSetConfigFilterProperty) F(MFXCreateSession) F(MFXClose) F(MFXQueryVersion) F(MFXVideoCORE_SetHandle) F(MFXVideoENCODE_Query) F(MFXVideoENCODE_Init) F(MFXVideoENCODE_GetVideoParam) F(MFXVideoENCODE_Close) F(MFXMemory_GetSurfaceForEncode) F(MFXVideoENCODE_EncodeFrameAsync) F(MFXVideoCORE_SyncOperation)
APIS(API)
void mcheck(mfxStatus s,const char* what){if(s<0){std::fprintf(stderr,"error=%s status=%d\n",what,s);throw std::runtime_error(what);}}
void hcheck(HRESULT h,const char* what){if(FAILED(h)){std::fprintf(stderr,"error=%s hr=%08lx\n",what,(unsigned long)h);throw std::runtime_error(what);}}
double clockms(){return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();}
int main(int argc,char** argv){
 HMODULE dll{};mfxLoader loader{};mfxSession session{};FILE* file{};bool started=false;
 try{
  const unsigned low=argc>1?std::strtoul(argv[1],nullptr,10):1;
  const unsigned width=argc>2?std::strtoul(argv[2],nullptr,10):6144;
  const unsigned height=argc>3?std::strtoul(argv[3],nullptr,10):3456;
  if(argc>4){fopen_s(&file,argv[4],"wb");if(!file)throw std::runtime_error("output open");}
  dll=LoadLibraryExW(L"libvpl.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);if(!dll)throw std::runtime_error("libvpl load");
  #define LOAD(name) p##name=reinterpret_cast<decltype(p##name)>(GetProcAddress(dll,#name));if(!p##name)throw std::runtime_error(#name);
  APIS(LOAD)
  loader=pMFXLoad();if(!loader)throw std::runtime_error("MFXLoad");
  auto filter=[&](const char* key,mfxU32 value){auto c=pMFXCreateConfig(loader);if(!c)throw std::runtime_error("config");mfxVariant v{};v.Type=MFX_VARIANT_TYPE_U32;v.Data.U32=value;mcheck(pMFXSetConfigFilterProperty(c,(mfxU8*)key,v),key);};
  filter("mfxImplDescription.Impl",MFX_IMPL_TYPE_HARDWARE);
  filter("mfxImplDescription.AccelerationMode",MFX_ACCEL_MODE_VIA_D3D11);
  filter("mfxImplDescription.ApiVersion.Version",(2u<<16)|2);
  filter("mfxImplDescription.mfxEncoderDescription.encoder.CodecID",MFX_CODEC_HEVC);
  mcheck(pMFXCreateSession(loader,0,&session),"session");mfxVersion ver{};mcheck(pMFXQueryVersion(session,&ver),"version");
  std::fprintf(stderr,"vpl_api=%u.%u\n",ver.Major,ver.Minor);
  ComPtr<ID3D11Device> dev;ComPtr<ID3D11DeviceContext> ctx;D3D_FEATURE_LEVEL fl{};
  hcheck(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT|D3D11_CREATE_DEVICE_VIDEO_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&dev,&fl,&ctx),"device");
  ComPtr<ID3D11Multithread> mt;hcheck(dev.As(&mt),"multithread");mt->SetMultithreadProtected(TRUE);
  mcheck(pMFXVideoCORE_SetHandle(session,MFX_HANDLE_D3D11_DEVICE,dev.Get()),"device handle");
  mfxVideoParam params{};params.AsyncDepth=1;params.IOPattern=MFX_IOPATTERN_IN_VIDEO_MEMORY;
  auto& m=params.mfx;m.CodecId=MFX_CODEC_HEVC;m.CodecProfile=MFX_PROFILE_HEVC_MAIN;m.TargetUsage=MFX_TARGETUSAGE_BEST_SPEED;m.LowPower=low?MFX_CODINGOPTION_ON:MFX_CODINGOPTION_OFF;
  m.TargetKbps=24000;m.MaxKbps=24000;m.RateControlMethod=MFX_RATECONTROL_CBR;m.GopPicSize=120;m.GopRefDist=1;m.NumRefFrame=1;
  auto& i=m.FrameInfo;i.FourCC=MFX_FOURCC_NV12;i.ChromaFormat=MFX_CHROMAFORMAT_YUV420;i.Width=(width+15)&~15;i.Height=(height+15)&~15;i.CropW=width;i.CropH=height;i.FrameRateExtN=60;i.FrameRateExtD=1;i.PicStruct=MFX_PICSTRUCT_PROGRESSIVE;
  mfxExtHEVCTiles tiles{};tiles.Header={MFX_EXTBUFF_HEVC_TILES,sizeof(tiles)};tiles.NumTileRows=1;tiles.NumTileColumns=argc>5?std::strtoul(argv[5],nullptr,10):1;
  mfxExtBuffer* ext[]={&tiles.Header};params.ExtParam=ext;params.NumExtParam=1;
  const auto q=pMFXVideoENCODE_Query(session,&params,&params);std::fprintf(stderr,"query=%d low=%u usage=%u width=%u height=%u refdist=%u refs=%u async=%u bitrate=%u\n",q,m.LowPower,m.TargetUsage,i.CropW,i.CropH,m.GopRefDist,m.NumRefFrame,params.AsyncDepth,m.TargetKbps);mcheck(q,"query");
  const auto init=pMFXVideoENCODE_Init(session,&params);std::fprintf(stderr,"init=%d\n",init);mcheck(init,"init");started=true;
  mcheck(pMFXVideoENCODE_GetVideoParam(session,&params),"actual params");std::fprintf(stderr,"actual low=%u usage=%u width=%u height=%u refdist=%u refs=%u async=%u bitrate=%u bufferkb=%u\n",m.LowPower,m.TargetUsage,i.CropW,i.CropH,m.GopRefDist,m.NumRefFrame,params.AsyncDepth,m.TargetKbps,m.BufferSizeInKB);
  std::fprintf(stderr,"tiles columns=%u rows=%u slices=%u\n",tiles.NumTileColumns,tiles.NumTileRows,m.NumSlice);
  ComPtr<ID3D11VideoDevice> vd;ComPtr<ID3D11VideoContext> vc;hcheck(dev.As(&vd),"video dev");hcheck(ctx.As(&vc),"video ctx");
  D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd{};cd.InputFrameFormat=D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;cd.InputWidth=cd.OutputWidth=width;cd.InputHeight=cd.OutputHeight=height;cd.InputFrameRate=cd.OutputFrameRate={60,1};cd.Usage=D3D11_VIDEO_USAGE_OPTIMAL_SPEED;
  ComPtr<ID3D11VideoProcessorEnumerator> en;ComPtr<ID3D11VideoProcessor> vp;hcheck(vd->CreateVideoProcessorEnumerator(&cd,&en),"enumerator");hcheck(vd->CreateVideoProcessor(en.Get(),0,&vp),"processor");
  RECT rect{0,0,(LONG)width,(LONG)height};vc->VideoProcessorSetStreamSourceRect(vp.Get(),0,TRUE,&rect);vc->VideoProcessorSetStreamDestRect(vp.Get(),0,TRUE,&rect);vc->VideoProcessorSetOutputTargetRect(vp.Get(),TRUE,&rect);
  D3D11_VIDEO_PROCESSOR_COLOR_SPACE rgb{},yuv{};yuv.YCbCr_Matrix=1;yuv.Nominal_Range=D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;vc->VideoProcessorSetStreamColorSpace(vp.Get(),0,&rgb);vc->VideoProcessorSetOutputColorSpace(vp.Get(),&yuv);
  D3D11_TEXTURE2D_DESC td{};td.Width=width;td.Height=height;td.ArraySize=td.MipLevels=td.SampleDesc.Count=1;td.Format=DXGI_FORMAT_B8G8R8A8_UNORM;td.BindFlags=D3D11_BIND_RENDER_TARGET;
  ComPtr<ID3D11Texture2D> texture;ComPtr<ID3D11RenderTargetView> target;hcheck(dev->CreateTexture2D(&td,nullptr,&texture),"source texture");hcheck(dev->CreateRenderTargetView(texture.Get(),nullptr,&target),"rtv");
  D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd{};ivd.ViewDimension=D3D11_VPIV_DIMENSION_TEXTURE2D;ComPtr<ID3D11VideoProcessorInputView> iv;hcheck(vd->CreateVideoProcessorInputView(texture.Get(),en.Get(),&ivd,&iv),"input view");
  auto convertedDesc=td;convertedDesc.Format=DXGI_FORMAT_NV12;ComPtr<ID3D11Texture2D> converted;
  hcheck(dev->CreateTexture2D(&convertedDesc,nullptr,&converted),"converted texture");
  D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd{};ovd.ViewDimension=D3D11_VPOV_DIMENSION_TEXTURE2D;ComPtr<ID3D11VideoProcessorOutputView> ov;
  hcheck(vd->CreateVideoProcessorOutputView(converted.Get(),en.Get(),&ovd,&ov),"output view");
  ComPtr<ID3D11Query> disjoint,timestamps[3];D3D11_QUERY_DESC qd{D3D11_QUERY_TIMESTAMP_DISJOINT,0};hcheck(dev->CreateQuery(&qd,&disjoint),"disjoint query");qd.Query=D3D11_QUERY_TIMESTAMP;for(auto& stamp:timestamps)hcheck(dev->CreateQuery(&qd,&stamp),"timestamp query");
  std::vector<mfxU8> buffer(16*1024*1024);unsigned received=0;const auto begin=clockms();
  for(unsigned frame=0;frame<120;++frame){
   const auto t0=clockms();mfxFrameSurface1* surface{};mcheck(pMFXMemory_GetSurfaceForEncode(session,&surface),"surface");
   mfxHDL handle{};mfxResourceType rt{};auto status=surface->FrameInterface->GetNativeHandle(surface,&handle,&rt);
   if(status<0){surface->FrameInterface->Release(surface);mcheck(status,"native handle");}
   auto native=static_cast<ID3D11Texture2D*>(handle);D3D11_TEXTURE2D_DESC actual{};native->GetDesc(&actual);
   if(frame==0)std::fprintf(stderr,"surface type=%d w=%u h=%u array=%u bind=%u format=%u\n",rt,actual.Width,actual.Height,actual.ArraySize,actual.BindFlags,actual.Format);
   const float color[4]={float(frame%60)/60.0f,0.3f,0.5f,1.0f};ctx->ClearRenderTargetView(target.Get(),color);
   D3D11_VIDEO_PROCESSOR_STREAM stream{};stream.Enable=TRUE;stream.pInputSurface=iv.Get();ctx->Begin(disjoint.Get());ctx->End(timestamps[0].Get());auto hr=vc->VideoProcessorBlt(vp.Get(),ov.Get(),0,1,&stream);ctx->End(timestamps[1].Get());ctx->CopyResource(native,converted.Get());ctx->End(timestamps[2].Get());ctx->End(disjoint.Get());ctx->Flush();
   if(FAILED(hr)){surface->FrameInterface->Release(surface);hcheck(hr,"blt");}
   surface->Data.TimeStamp=frame*1500;surface->Data.FrameOrder=frame;
   mfxBitstream bs{};bs.Data=buffer.data();bs.MaxLength=(mfxU32)buffer.size();mfxSyncPoint sync{};const auto t1=clockms();
   status=pMFXVideoENCODE_EncodeFrameAsync(session,nullptr,surface,&bs,&sync);surface->FrameInterface->Release(surface);const auto t2=clockms();if(status!=MFX_ERR_NONE){std::fprintf(stderr,"encode status=%d\n",status);throw std::runtime_error("encode not ready");}
   if(!sync)throw std::runtime_error("no sync");const auto synced=pMFXVideoCORE_SyncOperation(session,sync,5000);if(synced!=MFX_ERR_NONE){std::fprintf(stderr,"sync status=%d\n",synced);throw std::runtime_error("sync incomplete");}const auto t3=clockms();
   D3D11_QUERY_DATA_TIMESTAMP_DISJOINT dj{};UINT64 ts[3]{};bool measured=ctx->GetData(disjoint.Get(),&dj,sizeof(dj),0)==S_OK;for(unsigned j=0;j<3;++j)measured=measured && ctx->GetData(timestamps[j].Get(),&ts[j],sizeof(ts[j]),0)==S_OK;
   if(measured && !dj.Disjoint && dj.Frequency)std::fprintf(stderr,"gpu frame=%u convert=%.4f copy=%.4f\n",frame,1000.0*(ts[1]-ts[0])/dj.Frequency,1000.0*(ts[2]-ts[1])/dj.Frequency);
   if(file && fwrite(bs.Data+bs.DataOffset,1,bs.DataLength,file)!=bs.DataLength)throw std::runtime_error("output write");++received;
   std::fprintf(stderr,"frame=%u prepare=%.4f submit=%.4f sync=%.4f total=%.4f bytes=%u pts=%llu type=%u\n",frame,t1-t0,t2-t1,t3-t2,t3-t0,bs.DataLength,bs.TimeStamp,bs.FrameType);
  }
  std::fprintf(stderr,"result frames=%u elapsed=%.4f\n",received,clockms()-begin);
  pMFXVideoENCODE_Close(session);started=false;pMFXClose(session);session=nullptr;pMFXUnload(loader);loader=nullptr;if(file)fclose(file);FreeLibrary(dll);return 0;
 }catch(const std::exception& e){std::fprintf(stderr,"failed=%s\n",e.what());if(started)pMFXVideoENCODE_Close(session);if(session)pMFXClose(session);if(loader)pMFXUnload(loader);if(file)fclose(file);if(dll)FreeLibrary(dll);return 1;}
}
