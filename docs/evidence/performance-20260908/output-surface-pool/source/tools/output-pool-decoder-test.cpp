#include "../platform/windows-video-compositor/video_compositor.h"
#include <mfapi.h>
#include <fstream>
#include <iostream>
#include <stdexcept>
using namespace viewflow::windows;
using Microsoft::WRL::ComPtr;
static void check(bool ok,const char*msg){if(!ok)throw std::runtime_error(msg);}
static void hr(HRESULT h){if(FAILED(h)){std::cerr<<"HRESULT="<<std::hex<<unsigned(h)<<std::dec<<"\n";throw std::runtime_error("D3D/MF error");}}
static uint8_t alpha(uint64_t id,UINT x,UINT y){return uint8_t((id*17+x/64+y/32)%256);}
static uint64_t verify(GpuVideoCompositor& g,ID3D11Texture2D* texture,uint64_t id){D3D11_TEXTURE2D_DESC d{};texture->GetDesc(&d);check(d.Width==3840&&d.Height==2400,"decoded geometry");d.Usage=D3D11_USAGE_STAGING;d.BindFlags=0;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;d.MiscFlags=0;ComPtr<ID3D11Texture2D> t;hr(g.device()->CreateTexture2D(&d,nullptr,&t));g.context()->CopyResource(t.Get(),texture);D3D11_MAPPED_SUBRESOURCE m{};hr(g.context()->Map(t.Get(),0,D3D11_MAP_READ,0,&m));uint64_t hash=14695981039346656037ull;bool same=true;for(UINT y=0;y<d.Height;++y){auto p=static_cast<const uint8_t*>(m.pData)+size_t(y)*m.RowPitch;for(UINT x=0;x<d.Width;++x){same=same&&(p[x*4+3]==alpha(id,x,y));for(int k=0;k<4;++k){hash^=p[x*4+k];hash*=1099511628211ull;}}}g.context()->Unmap(t.Get(),0);check(same,"alpha is not current frame");std::cout<<"readback id="<<id<<" alpha_exact=1 bgra_fnv64="<<hash<<" bytes="<<3840ull*2400*4<<"\n";return hash;}
int main(int argc,char**argv){try{check(argc==3,"usage fixture.h264 pool0or1");bool pool=std::string(argv[2])=="1";std::ifstream file(argv[1],std::ios::binary);std::vector<uint8_t> au((std::istreambuf_iterator<char>(file)),{});check(!au.empty(),"empty fixture");hr(CoInitializeEx(nullptr,COINIT_MULTITHREADED));hr(MFStartup(MF_VERSION));{
 GpuVideoCompositor g;hr(GpuVideoCompositor::Create(&g,0,2,pool));std::vector<CompositedFrame> retained;ComPtr<ID3D11Texture2D> legacy_alias;uint64_t legacy_id{},count{},pool_hits{};std::vector<CompositedFrame> completed;
 auto consume=[&](){for(auto& f:completed){++count;check(bool(f.output_owner)==pool,"frame owner mode");verify(g,f.premultiplied_bgra.Get(),f.frame_identity);if(f.frame_identity<=5)retained.push_back(f);if(!pool&&!legacy_alias){legacy_alias=f.premultiplied_bgra;legacy_id=f.frame_identity;}}completed.clear();};
 for(uint64_t id=1;id<=24;++id){if(id==8)retained.clear();auto mask=std::make_shared<std::vector<uint8_t>>(3840*2400);for(UINT y=0;y<2400;++y)for(UINT x=0;x<3840;++x)(*mask)[size_t(y)*3840+x]=alpha(id,x,y);hr(g.Submit(id,au,{id,3840,2400,*mask,mask},&completed));auto t=g.last_submit_host_durations();pool_hits=t.output_pool.reused;std::cout<<"submit id="<<id<<" completed="<<completed.size()<<" pool_acquires="<<t.output_pool.acquisitions<<" pool_created="<<t.output_pool.created<<" pool_reused="<<t.output_pool.reused<<" pool_fallback="<<t.output_pool.fallback<<"\n";consume();if(id==7){check(retained.size()==5,"retained outputs missing");for(auto& f:retained)verify(g,f.premultiplied_bgra.Get(),f.frame_identity);}}
 hr(g.Finish(&completed));consume();check(count==24,"missing decoded frame");if(pool)check(pool_hits>10,"pool integration did not reuse");if(!pool){check(legacy_alias&&legacy_id==1,"legacy alias missing");verify(g,legacy_alias.Get(),legacy_id);}std::cout<<"PASS decoder_integration pool="<<pool<<" frames="<<count<<"\n";
 }MFShutdown();CoUninitialize();return 0;
}catch(const std::exception&e){std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}}
