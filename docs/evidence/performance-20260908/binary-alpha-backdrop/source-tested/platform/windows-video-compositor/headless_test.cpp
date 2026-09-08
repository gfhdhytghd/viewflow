#include "video_compositor.h"
#include <mfapi.h>
#include <windows.h>

#include <algorithm>
#include <filesystem>
#include <chrono>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>
#include <vector>

using namespace viewflow::windows;
static std::string Hex(HRESULT h) { std::ostringstream s; s << "0x" << std::hex << static_cast<unsigned long>(h); return s.str(); }
static bool Read(const std::filesystem::path& p, std::vector<uint8_t>* v) { std::ifstream f(p,std::ios::binary|std::ios::ate); if(!f)return false; auto n=f.tellg(); if(n<=0)return false; v->resize(size_t(n)); f.seekg(0); f.read(reinterpret_cast<char*>(v->data()),n); return bool(f); }
static bool ParseU32(const wchar_t* text, uint32_t* value) { try { size_t used{}; auto parsed=std::stoul(text,&used,10); if(text[used] || parsed>std::numeric_limits<uint32_t>::max()) return false; *value=static_cast<uint32_t>(parsed); return true; } catch(...) { return false; } }
static void PrintGeometry(const GpuVideoCompositor& compositor, const char* phase) { auto g=compositor.decoder_geometry(); std::cout<<phase<<" negotiated="<<g.negotiated_width<<"x"<<g.negotiated_height<<" texture="<<g.texture_width<<"x"<<g.texture_height<<" aperture="; if(g.has_minimum_display_aperture) std::cout<<g.aperture_x<<","<<g.aperture_y<<","<<g.aperture_width<<"x"<<g.aperture_height; else std::cout<<"none"; std::cout<<"\n"; }
static HRESULT ReadbackAlpha(ID3D11Device* d, ID3D11DeviceContext* c, ID3D11Texture2D* source, std::vector<uint8_t>* alpha) {
  D3D11_TEXTURE2D_DESC x{}; source->GetDesc(&x); x.Usage=D3D11_USAGE_STAGING; x.BindFlags=0; x.CPUAccessFlags=D3D11_CPU_ACCESS_READ; x.MiscFlags=0; Microsoft::WRL::ComPtr<ID3D11Texture2D> copy; HRESULT hr=d->CreateTexture2D(&x,nullptr,&copy); if(FAILED(hr))return hr; c->CopyResource(copy.Get(),source); D3D11_MAPPED_SUBRESOURCE m{}; hr=c->Map(copy.Get(),0,D3D11_MAP_READ,0,&m); if(FAILED(hr))return hr; alpha->clear(); for(UINT y=0;y<x.Height;++y){auto row=static_cast<uint8_t*>(m.pData)+size_t(y)*m.RowPitch; for(UINT col=0;col<x.Width;++col)alpha->push_back(row[col*4+3]);} c->Unmap(copy.Get(),0); return S_OK;
}
int wmain(int n,wchar_t** v) {
  std::cout << std::unitbuf; std::cerr << std::unitbuf;
  if(n!=2 && n!=4){std::cerr<<"usage: viewflow_windows_video_compositor_test <fixture-dir> [width height]\n";return 64;} uint32_t width=256,height=256; if(n==4 && (!ParseU32(v[2],&width)||!ParseU32(v[3],&height)||!width||!height)){std::cerr<<"invalid fixture geometry\n";return 64;} HRESULT hr=CoInitializeEx(nullptr,COINIT_MULTITHREADED); if(FAILED(hr))return 2; hr=MFStartup(MF_VERSION); if(FAILED(hr)){CoUninitialize();return 2;}
  int exit_code = [&]() -> int {
  GpuVideoCompositor compositor; hr=GpuVideoCompositor::Create(&compositor); std::cout<<"create_gpu_high_h264_compositor="<<Hex(hr)<<"\n"; if(FAILED(hr)){std::cout<<"CAPABILITY_MISSING hardware_mf_high_h264_or_planar_srv\n";return 3;}
  const uint64_t pixels=uint64_t(width)*height; std::filesystem::path dir=v[1]; std::vector<uint8_t> expected; if(!pixels||pixels>SIZE_MAX/3||!Read(dir/L"expected-alpha.gray",&expected)||expected.size()!=3*pixels){std::cerr<<"fixture invalid\n";return 65;} std::vector<CompositedFrame> frames;
  std::shared_ptr<const std::vector<uint8_t>> alpha_owner;
  for(uint64_t i=1;i<=3;++i) {
    std::vector<uint8_t> au;
    if(!Read(dir/(L"color-"+std::to_wstring(i)+L".h264"),&au)) { std::cerr<<"missing color AU\n"; return 65; }
    auto begin=expected.begin()+ptrdiff_t((i-1)*pixels);
    const std::span<const uint8_t> samples(begin, begin + pixels);
    if (!alpha_owner || !std::ranges::equal(*alpha_owner, samples))
      alpha_owner = std::make_shared<const std::vector<uint8_t>>(samples.begin(), samples.end());
    RawGray8Alpha a{i,width,height,*alpha_owner,alpha_owner};
    auto before=frames.size();
    hr=compositor.Submit(i,au,a,&frames);
    const auto timing=compositor.last_submit_host_durations();
    std::cout<<"submit="<<i<<" hr="<<Hex(hr)<<" completed_delta="<<(frames.size()-before)<<" completed_total="<<frames.size()<<" expected="<<width<<"x"<<height<<" host_submit_us="<<timing.total_submit_us<<" host_alpha_texture_create_us="<<timing.alpha_texture_create_us<<" host_alpha_texture_reused="<<(timing.alpha_texture_reused?"true":"false")<<" host_mf_sample_copy_us="<<timing.mf_sample_copy_us<<" host_mf_process_input_us="<<timing.mf_process_input_us<<" host_mf_process_output_us="<<timing.mf_process_output_us<<" host_composite_gpu_resource_alloc_us="<<timing.composite_gpu_resource_alloc_us<<" host_composite_video_processor_us="<<timing.composite_video_processor_us<<" host_composite_shader_us="<<timing.composite_shader_us<<"\n";
    PrintGeometry(compositor,"submit_geometry");
    if(FAILED(hr)) { std::cout<<"CAPABILITY_MISSING planar_nv12_shader_sampling_or_gpu_copy\n"; return 3; }
    const bool expected_alpha_texture_reused =
        i > 1 && std::equal(begin, begin + ptrdiff_t(pixels),
                             expected.begin() + ptrdiff_t((i - 2) * pixels));
    if (timing.frame_identity != i ||
        timing.alpha_texture_reused != expected_alpha_texture_reused) {
      std::cerr << "alpha texture reuse result differs from consecutive exact alpha equality\n";
      return 6;
    }
  }
  hr=compositor.Finish(&frames); std::cout<<"finish hr="<<Hex(hr)<<" completed="<<frames.size()<<"\n"; if(FAILED(hr)||frames.size()!=3)return 4;
  PrintGeometry(compositor,"finish_geometry");
  for(auto const& frame:frames){std::vector<uint8_t> actual;hr=ReadbackAlpha(compositor.device(),compositor.context(),frame.premultiplied_bgra.Get(),&actual);auto begin=expected.begin()+ptrdiff_t((frame.frame_identity-1)*pixels); bool exact=frame.width==width&&frame.height==height&&SUCCEEDED(hr)&&std::equal(actual.begin(),actual.end(),begin,begin+pixels);std::cout<<"frame="<<frame.frame_identity<<" dimensions="<<frame.width<<"x"<<frame.height<<" alpha_readback_test_exact="<<(exact?"true":"false")<<" bytes="<<actual.size()<<"\n";if(!exact)return 5;}
  std::cout<<"PASS gpu_color_no_readback raw_alpha_exact_composition=3\n";return 0;
  }();
  MFShutdown(); CoUninitialize(); return exit_code;
}
