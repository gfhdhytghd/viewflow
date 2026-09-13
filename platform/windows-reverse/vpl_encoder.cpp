#include "vpl_encoder.hpp"
#include "diagnostics.hpp"
#include <d3d11_4.h>
#include <wrl/client.h>
#include <vpl/mfxdispatcher.h>
#include <vpl/mfxvideo.h>
#include <cstdio>
#include <vector>
#include <cstdlib>
#include <cstring>
#include <array>
#include <deque>
#include <map>
#include <algorithm>
#include "vpl_allocator.hpp"
namespace viewflow::reverse {
using Microsoft::WRL::ComPtr;
#define VF_VPL_FUNCTIONS(F) F(MFXLoad) F(MFXUnload) F(MFXCreateConfig) F(MFXSetConfigFilterProperty) F(MFXCreateSession) F(MFXClose) F(MFXQueryVersion) F(MFXVideoCORE_SetHandle) F(MFXVideoCORE_SetFrameAllocator) F(MFXVideoENCODE_QueryIOSurf) F(MFXVideoENCODE_Query) F(MFXVideoENCODE_Init) F(MFXVideoENCODE_GetVideoParam) F(MFXVideoENCODE_Close) F(MFXVideoENCODE_EncodeFrameAsync) F(MFXVideoCORE_SyncOperation)
#define VF_HR(expr) do { const HRESULT r=(expr);if(FAILED(r)){std::fprintf(stderr,"vpl error=%s hr=%08lx\n",#expr,(unsigned long)r);return r;}}while(0)
#define VF_MFX(expr) do { const mfxStatus r=(expr);if(r<0){std::fprintf(stderr,"vpl error=%s status=%d\n",#expr,r);return E_FAIL;}}while(0)
static long long clock100ns(){LARGE_INTEGER t{},f{};QueryPerformanceCounter(&t);QueryPerformanceFrequency(&f);return t.QuadPart/f.QuadPart*10000000+(t.QuadPart%f.QuadPart)*10000000/f.QuadPart;}
struct VplEncoder::Impl {
 #define DECLARE(name) decltype(&name) p##name{};
 VF_VPL_FUNCTIONS(DECLARE)
 #undef DECLARE
 HMODULE dll{};mfxLoader loader{};mfxSession session{};bool started{};
 VplAllocator allocator;
 ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;ComPtr<ID3D11VideoDevice> video;ComPtr<ID3D11VideoContext> video_context;
 ComPtr<ID3D11VideoProcessorEnumerator> enumeration;ComPtr<ID3D11VideoProcessor> processor;
 struct Input {ComPtr<ID3D11Texture2D> nv12;ComPtr<ID3D11VideoProcessorOutputView> output;VplMemory memory;mfxFrameSurface1 surface{};};
 struct Task {std::vector<mfxU8> bytes;mfxBitstream bitstream{};mfxSyncPoint sync{};};
 std::vector<std::unique_ptr<Input>> inputs;std::array<Task,2> tasks;std::deque<unsigned> pending;
 std::map<mfxU64,std::int64_t> timestamps;
 bool draining{};unsigned width{},height{},fps{},depth{2};std::uint64_t serial{};
 Input* free_input(){for(auto& input:inputs)if(!input->surface.Data.Locked)return input.get();return nullptr;}
 ~Impl(){if(started)pMFXVideoENCODE_Close(session);if(session)pMFXClose(session);if(loader)pMFXUnload(loader);if(dll)FreeLibrary(dll);}
 HRESULT filter(const char* key,mfxU32 value){auto c=pMFXCreateConfig(loader);if(!c)return E_OUTOFMEMORY;mfxVariant v{};v.Type=MFX_VARIANT_TYPE_U32;v.Data.U32=value;VF_MFX(pMFXSetConfigFilterProperty(c,(mfxU8*)key,v));return S_OK;}
};
VplEncoder::VplEncoder():impl_(std::make_unique<Impl>()){}
VplEncoder::~VplEncoder()=default;
HRESULT VplEncoder::start(ID3D11Device* device,unsigned width,unsigned height,unsigned fps,unsigned codec){
 auto& s=*impl_;if(!device||s.session||codec!=2||!width||!height||width%2||height%2||!fps||width>16368||height>16368)return E_INVALIDARG;
 s.dll=LoadLibraryExW(L"libvpl.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);if(!s.dll)return HRESULT_FROM_WIN32(GetLastError());
 #define LOAD(name) s.p##name=reinterpret_cast<decltype(s.p##name)>(GetProcAddress(s.dll,#name));if(!s.p##name)return E_NOINTERFACE;
 VF_VPL_FUNCTIONS(LOAD)
 #undef LOAD
 s.loader=s.pMFXLoad();if(!s.loader)return E_FAIL;
 VF_HR(s.filter("mfxImplDescription.Impl",MFX_IMPL_TYPE_HARDWARE));VF_HR(s.filter("mfxImplDescription.AccelerationMode",MFX_ACCEL_MODE_VIA_D3D11));VF_HR(s.filter("mfxImplDescription.ApiVersion.Version",(2u<<16)|2));VF_HR(s.filter("mfxImplDescription.mfxEncoderDescription.encoder.CodecID",MFX_CODEC_HEVC));
 VF_MFX(s.pMFXCreateSession(s.loader,0,&s.session));mfxVersion version{};VF_MFX(s.pMFXQueryVersion(s.session,&version));
 s.device=device;device->GetImmediateContext(&s.context);VF_HR(s.device.As(&s.video));VF_HR(s.context.As(&s.video_context));
 VF_MFX(s.pMFXVideoCORE_SetHandle(s.session,MFX_HANDLE_D3D11_DEVICE,device));s.allocator.device=device;s.allocator.context=s.context;VF_MFX(s.pMFXVideoCORE_SetFrameAllocator(s.session,&s.allocator.callbacks));
 if(const auto env=std::getenv("VIEWFLOW_REVERSE_VPL_DEPTH");env && (std::strcmp(env,"1")==0||std::strcmp(env,"2")==0))s.depth=static_cast<unsigned>(std::atoi(env));
 mfxVideoParam p{};p.AsyncDepth=static_cast<mfxU16>(s.depth);p.IOPattern=MFX_IOPATTERN_IN_VIDEO_MEMORY;
 auto& m=p.mfx;m.CodecId=MFX_CODEC_HEVC;m.CodecProfile=MFX_PROFILE_HEVC_MAIN;m.TargetUsage=MFX_TARGETUSAGE_BEST_SPEED;m.LowPower=MFX_CODINGOPTION_ON;m.TargetKbps=m.MaxKbps=24000;m.RateControlMethod=MFX_RATECONTROL_CBR;m.GopPicSize=fps*2;m.GopRefDist=1;m.NumRefFrame=1;
 auto& i=m.FrameInfo;i.FourCC=MFX_FOURCC_NV12;i.ChromaFormat=MFX_CHROMAFORMAT_YUV420;i.Width=(width+15)&~15;i.Height=(height+15)&~15;i.CropW=width;i.CropH=height;i.FrameRateExtN=fps;i.FrameRateExtD=1;i.PicStruct=MFX_PICSTRUCT_PROGRESSIVE;
 mfxExtHEVCTiles tiles{};tiles.Header={MFX_EXTBUFF_HEVC_TILES,sizeof(tiles)};tiles.NumTileRows=1;tiles.NumTileColumns=width>=1024?2:1;
 if(const auto env=std::getenv("VIEWFLOW_REVERSE_VPL_TILES");env && (std::strcmp(env,"1")==0||std::strcmp(env,"2")==0||std::strcmp(env,"4")==0))tiles.NumTileColumns=std::atoi(env);
 mfxExtBuffer* ext[]={&tiles.Header};p.ExtParam=ext;p.NumExtParam=1;
 const auto query=s.pMFXVideoENCODE_Query(s.session,&p,&p);VF_MFX(query);mfxFrameAllocRequest request{};VF_MFX(s.pMFXVideoENCODE_QueryIOSurf(s.session,&p,&request));VF_MFX(s.pMFXVideoENCODE_Init(s.session,&p));s.started=true;VF_MFX(s.pMFXVideoENCODE_GetVideoParam(s.session,&p));
 std::fprintf(stderr,"encoder_vpl api=%u.%u query=%d width=%u height=%u low=%u usage=%u async=%u refdist=%u refs=%u tiles=%u rows=%u slices=%u bitrate=%u\n",version.Major,version.Minor,query,i.CropW,i.CropH,m.LowPower,m.TargetUsage,p.AsyncDepth,m.GopRefDist,m.NumRefFrame,tiles.NumTileColumns,tiles.NumTileRows,m.NumSlice,m.TargetKbps);
 if(i.CropW!=width||i.CropH!=height||i.FourCC!=MFX_FOURCC_NV12||m.GopRefDist!=1||p.AsyncDepth!=s.depth)return E_FAIL;
 D3D11_VIDEO_PROCESSOR_CONTENT_DESC d{};d.InputFrameFormat=D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;d.InputWidth=d.OutputWidth=width;d.InputHeight=d.OutputHeight=height;d.InputFrameRate=d.OutputFrameRate={fps,1};d.Usage=D3D11_VIDEO_USAGE_OPTIMAL_SPEED;
 VF_HR(s.video->CreateVideoProcessorEnumerator(&d,&s.enumeration));VF_HR(s.video->CreateVideoProcessor(s.enumeration.Get(),0,&s.processor));RECT rect{0,0,(LONG)width,(LONG)height};
 s.video_context->VideoProcessorSetStreamSourceRect(s.processor.Get(),0,TRUE,&rect);s.video_context->VideoProcessorSetStreamDestRect(s.processor.Get(),0,TRUE,&rect);s.video_context->VideoProcessorSetOutputTargetRect(s.processor.Get(),TRUE,&rect);s.video_context->VideoProcessorSetStreamFrameFormat(s.processor.Get(),0,D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
 D3D11_VIDEO_PROCESSOR_COLOR_SPACE rgb{},yuv{};yuv.YCbCr_Matrix=1;yuv.Nominal_Range=D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;s.video_context->VideoProcessorSetStreamColorSpace(s.processor.Get(),0,&rgb);s.video_context->VideoProcessorSetOutputColorSpace(s.processor.Get(),&yuv);
 const unsigned count=std::max({s.depth+1,unsigned(request.NumFrameMin),unsigned(request.NumFrameSuggested)});
 for(unsigned n=0;n<count;++n){auto input=std::make_unique<Impl::Input>();
  D3D11_TEXTURE2D_DESC td{};td.Width=i.Width;td.Height=i.Height;td.MipLevels=td.ArraySize=td.SampleDesc.Count=1;td.Format=DXGI_FORMAT_NV12;td.BindFlags=D3D11_BIND_RENDER_TARGET;VF_HR(s.device->CreateTexture2D(&td,nullptr,&input->nv12));
  D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ov{};ov.ViewDimension=D3D11_VPOV_DIMENSION_TEXTURE2D;VF_HR(s.video->CreateVideoProcessorOutputView(input->nv12.Get(),s.enumeration.Get(),&ov,&input->output));
  input->memory.resource=input->nv12;input->surface.Info=i;input->surface.Data.MemId=&input->memory;s.inputs.push_back(std::move(input));
 }
 for(auto& task:s.tasks)task.bytes.resize(16*1024*1024);
 std::fprintf(stderr,"encoder_vpl_pool depth=%u minimum=%u suggested=%u allocated=%u\n",s.depth,request.NumFrameMin,request.NumFrameSuggested,count);
 s.width=width;s.height=height;s.fps=fps;return S_OK;
}

HRESULT VplEncoder::can_submit(){auto& s=*impl_;if(!s.started)return E_UNEXPECTED;return !s.draining && s.pending.size()<s.depth && s.free_input()?S_OK:S_FALSE;}
HRESULT VplEncoder::submit(ID3D11Texture2D* bgra,std::int64_t pts,bool key){
 auto& s=*impl_;if(!s.started||!bgra||pts<0)return E_INVALIDARG;if(s.draining||s.pending.size()>=s.depth)return S_FALSE;auto* selected=s.free_input();if(!selected)return S_FALSE;auto& input_surface=*selected;
 unsigned task_index=0;while(task_index<s.depth && s.tasks[task_index].sync)++task_index;if(task_index==s.depth)return S_FALSE;auto& task=s.tasks[task_index];
 D3D11_TEXTURE2D_DESC d{};bgra->GetDesc(&d);if(d.Width!=s.width||d.Height!=s.height||d.Format!=DXGI_FORMAT_B8G8R8A8_UNORM)return E_INVALIDARG;
 D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC iv{};iv.ViewDimension=D3D11_VPIV_DIMENSION_TEXTURE2D;ComPtr<ID3D11VideoProcessorInputView> input;VF_HR(s.video->CreateVideoProcessorInputView(bgra,s.enumeration.Get(),&iv,&input));D3D11_VIDEO_PROCESSOR_STREAM stream{};stream.Enable=TRUE;stream.pInputSurface=input.Get();VF_HR(s.video_context->VideoProcessorBlt(s.processor.Get(),input_surface.output.Get(),0,1,&stream));s.context->Flush();
 const auto token=s.serial*90000/s.fps;input_surface.surface.Data.TimeStamp=token;input_surface.surface.Data.FrameOrder=static_cast<mfxU32>(s.serial);task.bitstream={};task.bitstream.Data=task.bytes.data();task.bitstream.MaxLength=static_cast<mfxU32>(task.bytes.size());
 mfxEncodeCtrl control{};if(key)control.FrameType=MFX_FRAMETYPE_I|MFX_FRAMETYPE_IDR|MFX_FRAMETYPE_REF;
 const auto begin=clock100ns();const auto result=s.pMFXVideoENCODE_EncodeFrameAsync(s.session,&control,&input_surface.surface,&task.bitstream,&task.sync);
 if(vf_diag::enabled())std::fprintf(stderr,"encoder_input pts=%lld begin=%lld end=%lld mfx_status=%d token=%llu pending=%zu\n",pts,begin,clock100ns(),result,token,s.pending.size());
 if(result==MFX_WRN_DEVICE_BUSY && !task.sync)return S_FALSE;
 if((result!=MFX_ERR_NONE && result!=MFX_ERR_MORE_DATA)||(result==MFX_ERR_NONE && !task.sync)||(result==MFX_ERR_MORE_DATA && task.sync)){std::fprintf(stderr,"vpl submit status=%d sync=%p\n",result,task.sync);return E_FAIL;}
 if(!s.timestamps.emplace(token,pts).second)return E_FAIL;++s.serial;if(task.sync)s.pending.push_back(task_index);return S_OK;
}
HRESULT VplEncoder::request_output(){
 auto& s=*impl_;if(!s.started)return E_UNEXPECTED;
 if(!s.draining && s.timestamps.size()>s.pending.size()){
  s.draining=true;
  if(vf_diag::enabled())std::fprintf(stderr,"encoder_drain_begin pending=%zu accepted=%zu at=%lld\n",s.pending.size(),s.timestamps.size(),clock100ns());
 }
 return S_OK;
}
HRESULT VplEncoder::poll(std::vector<EncodedFrame>& frames){
 auto& s=*impl_;if(!s.started)return E_UNEXPECTED;
 while(!s.pending.empty()){
  auto& task=s.tasks[s.pending.front()];const auto begin=clock100ns();const auto result=s.pMFXVideoCORE_SyncOperation(s.session,task.sync,0);if(result==MFX_WRN_IN_EXECUTION)return S_OK;
  if(result!=MFX_ERR_NONE){std::fprintf(stderr,"vpl sync status=%d\n",result);return E_FAIL;}
  const auto stamp=s.timestamps.find(task.bitstream.TimeStamp);if(stamp==s.timestamps.end()||!task.bitstream.DataLength||task.bitstream.DataOffset>task.bitstream.MaxLength||task.bitstream.DataLength>task.bitstream.MaxLength-task.bitstream.DataOffset)return E_FAIL;
  EncodedFrame frame;frame.timestamp=stamp->second;frame.keyframe=(task.bitstream.FrameType&MFX_FRAMETYPE_IDR)!=0;frame.bytes.assign(task.bitstream.Data+task.bitstream.DataOffset,task.bitstream.Data+task.bitstream.DataOffset+task.bitstream.DataLength);
  if(vf_diag::enabled())std::fprintf(stderr,"encoder_output pts=%lld begin=%lld end=%lld bytes=%zu mfx_status=%d token=%llu\n",frame.timestamp,begin,clock100ns(),frame.bytes.size(),result,task.bitstream.TimeStamp);
  frames.push_back(std::move(frame));s.timestamps.erase(stamp);task.sync=nullptr;s.pending.pop_front();
 }
 if(s.draining){
  // Complete existing tasks before requesting cached output. Do not interleave
  // fresh input with draining. Confirm MORE_DATA before accepting input again.
  auto& task=s.tasks[0];task.bitstream={};task.bitstream.Data=task.bytes.data();task.bitstream.MaxLength=static_cast<mfxU32>(task.bytes.size());
  const auto begin=clock100ns();const auto status=s.pMFXVideoENCODE_EncodeFrameAsync(s.session,nullptr,nullptr,&task.bitstream,&task.sync);
  if(vf_diag::enabled())std::fprintf(stderr,"encoder_flush mfx_status=%d sync=%p pending=%zu accepted=%zu begin=%lld end=%lld\n",status,task.sync,s.pending.size(),s.timestamps.size(),begin,clock100ns());
  if(status==MFX_WRN_DEVICE_BUSY && !task.sync)return S_OK;
  if(status==MFX_ERR_MORE_DATA && !task.sync){
   if(!s.timestamps.empty())return E_FAIL;s.draining=false;
   if(vf_diag::enabled())std::fprintf(stderr,"encoder_drain_end at=%lld\n",clock100ns());
  }else if(status==MFX_ERR_NONE && task.sync)s.pending.push_back(0);
  else return E_FAIL;
 }
 return S_OK;
}
}
