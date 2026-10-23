// Real decoder + same-device drawing-surface oracle. Creates no HWND.
#define wmain unused_direct_output_preview_entry
#include "main.cpp"
#undef wmain
#include <filesystem>
#include <fstream>

static std::vector<uint8_t> read_region(ID3D11Device* device,ID3D11DeviceContext* context,
    ID3D11Texture2D* texture,UINT x,UINT y,UINT width,UINT height) {
  D3D11_TEXTURE2D_DESC d{};d.Width=width;d.Height=height;d.MipLevels=1;d.ArraySize=1;
  d.Format=DXGI_FORMAT_B8G8R8A8_UNORM;d.SampleDesc.Count=1;d.Usage=D3D11_USAGE_STAGING;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging;check_hresult(device->CreateTexture2D(&d,nullptr,staging.GetAddressOf()));
  const D3D11_BOX box{x,y,0,x+width,y+height,1};context->CopySubresourceRegion(staging.Get(),0,0,0,0,texture,0,&box);
  D3D11_MAPPED_SUBRESOURCE mapped{};check_hresult(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped));
  std::vector<uint8_t> pixels(size_t(width)*height*4);
  for(UINT row=0;row<height;++row)memcpy(pixels.data()+size_t(row)*width*4,static_cast<uint8_t*>(mapped.pData)+size_t(row)*mapped.RowPitch,size_t(width)*4);
  context->Unmap(staging.Get(),0);return pixels;
}
static int test(const wchar_t* path,FILE* log) {
  std::ifstream input(std::filesystem::path(path),std::ios::binary|std::ios::ate);
  if(!input)return 2;const auto size=input.tellg();input.seekg(0);
  std::vector<uint8_t> au(static_cast<size_t>(size));input.read(reinterpret_cast<char*>(au.data()),size);if(!input)return 2;
  viewflow::windows_preview::MtaVideoCompositor decoder;check_hresult(decoder.Initialize());
  init_apartment(apartment_type::single_threaded);
  DispatcherQueueOptions options{sizeof(options),DQTYPE_THREAD_CURRENT,DQTAT_COM_STA};
  com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;check_hresult(CreateDispatcherQueueController(options,queue.put()));
  Compositor compositor;auto owner=foreground(compositor,3840,2400,decoder.device());
  auto real_factory=direct_drawing_factory(owner.graphics,owner.d3d.get());
  constexpr UINT width=3840,height=2400;
  Microsoft::WRL::ComPtr<::IUnknown> reusable;
  const HWND original_foreground=GetForegroundWindow();
  for(unsigned mode=0;mode<7;++mode) {
    auto alpha=std::make_shared<std::vector<uint8_t>>(size_t(width)*height);
    for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x)
      (*alpha)[size_t(y)*width+x]=((x/91+y/73+mode)%7==0)?0:((x/67+y/83)%5==0)?255:uint8_t((x+3*y+mode*17)%256);
    const uint64_t reference_id=2*mode+1,candidate_id=reference_id+1;
    std::vector<viewflow::windows::CompositedFrame> reference,candidate;
    check_hresult(decoder.Invoke([&](auto& d){return d.Submit(reference_id,au,{reference_id,width,height,*alpha,alpha},&reference);}));
    if(reference.size()!=1 || reference[0].frame_identity!=reference_id)throw std::runtime_error("reference decode identity");
    auto expected=decoder.Invoke([&](auto& d){return read_region(d.device(),d.context(),reference[0].premultiplied_bgra.Get(),0,0,width,height);});
    auto actual=std::make_shared<std::vector<uint8_t>>();
    auto padding_ok=std::make_shared<bool>(true);
    decoder.Invoke([&](auto& d){
      auto device=d.device();auto context=d.context();
      d.SetDrawingTargetFactory([=](uint64_t id,uint32_t w,uint32_t h,::IUnknown* spare,viewflow::windows::DrawingTarget* out)->HRESULT {
        if(mode==3)return E_NOTIMPL; // optional preparation failure
        if(mode==2) {
          D3D11_TEXTURE2D_DESC desc{};desc.Width=w+16;desc.Height=h+12;desc.MipLevels=1;desc.ArraySize=1;
          desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
          std::vector<uint8_t> fill(size_t(desc.Width)*desc.Height*4,0x35);D3D11_SUBRESOURCE_DATA data{fill.data(),desc.Width*4,0};
          auto hr=device->CreateTexture2D(&desc,&data,out->texture.GetAddressOf());if(FAILED(hr))return hr;
          out->presentation_surface=out->texture;out->x=7;out->y=5;
          auto texture=out->texture;
          out->finish=[=]{
            *actual=read_region(device,context,texture.Get(),7,5,w,h);
            auto all=read_region(device,context,texture.Get(),0,0,desc.Width,desc.Height);
            for(UINT y=0;y<desc.Height;++y)for(UINT x=0;x<desc.Width;++x)if(x<7||x>=w+7||y<5||y>=h+5)
              for(unsigned c=0;c<4;++c)*padding_ok &= all[(size_t(y)*desc.Width+x)*4+c]==0x35;
            return S_OK;
          };return S_OK;
        }
        auto hr=real_factory(id,w,h,spare,out);if(FAILED(hr))return hr;
        if(mode==4){out->x=UINT_MAX;return S_OK;} // invalid region must close the lease
        auto close=out->finish;auto texture=out->texture;const auto x=out->x,y=out->y;
        out->finish=[=]{
          *actual=read_region(device,context,texture.Get(),x,y,w,h); // read while BeginDraw is open
          const auto result=close();return mode==5 && SUCCEEDED(result)?E_FAIL:result;
        };return S_OK;
      });
    });
    check_hresult(decoder.Invoke([&](auto& d){return d.Submit(candidate_id,au,{candidate_id,width,height,*alpha,alpha},&candidate,true,mode==1?reusable:Microsoft::WRL::ComPtr<::IUnknown>{});}));
    if(candidate.size()!=1 || candidate[0].frame_identity!=candidate_id)throw std::runtime_error("candidate decode identity");
    const bool direct=mode<3||mode==6;
    if(bool(candidate[0].presentation_surface)!=direct || bool(candidate[0].premultiplied_bgra)==direct)throw std::runtime_error("wrong direct/fallback ownership");
    if(!direct)*actual=decoder.Invoke([&](auto& d){return read_region(d.device(),d.context(),candidate[0].premultiplied_bgra.Get(),0,0,width,height);});
    if(mode==0)reusable=candidate[0].presentation_surface;
    if(actual->size()!=expected.size() || !*padding_ok)throw std::runtime_error("draw region or padding");
    unsigned max_rgb_error=0;size_t alpha_mismatches=0;
    for(size_t pixel=0;pixel<alpha->size();++pixel) {
      alpha_mismatches+=(*actual)[pixel*4+3]!=(*alpha)[pixel] || expected[pixel*4+3]!=(*alpha)[pixel];
      for(unsigned c=0;c<3;++c)max_rgb_error=std::max(max_rgb_error,unsigned(abs(int(expected[pixel*4+c])-int((*actual)[pixel*4+c]))));
    }
    std::fprintf(log,"direct-test mode=%u reference=%llu candidate=%llu direct=%u pixels=%u rgb_max_error=%u alpha_mismatches=%zu padding_preserved=%u\n",mode,reference_id,candidate_id,unsigned(direct),width*height,max_rgb_error,alpha_mismatches,unsigned(*padding_ok));std::fflush(log);
    if(max_rgb_error>1 || alpha_mismatches)throw std::runtime_error("pixel mismatch");
  }
  decoder.Invoke([](auto& d){d.SetDrawingTargetFactory({});});
  std::fprintf(log,"PASS direct output: real MTA drawing surface, reuse, shifted target, three fallbacks, recovery; foreground_unchanged=%u input_injected=0\n",unsigned(GetForegroundWindow()==original_foreground));
  return 0;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
  int argc{};auto args=CommandLineToArgvW(GetCommandLineW(),&argc);if(!args||argc!=3)return 2;
  FILE* log{};_wfopen_s(&log,args[2],L"w");if(!log)return 2;int code=1;
  try {code=test(args[1],log);}catch(const winrt::hresult_error& e){std::fprintf(log,"HRESULT=%08lx\n",static_cast<unsigned long>(e.code()));}
  catch(const std::exception& e){std::fprintf(log,"error=%s\n",e.what());}
  std::fclose(log);LocalFree(args);return code;
}
