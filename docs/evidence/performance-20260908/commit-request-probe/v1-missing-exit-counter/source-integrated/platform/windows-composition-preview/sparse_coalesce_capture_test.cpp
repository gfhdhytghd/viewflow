#define INITGUID
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
// GPU pixel oracle for eliding backdrop only behind decoded coalesce patches.
#define wmain viewflow_preview_entry_for_coalesce_test
#include "main.cpp"
#undef wmain
#include "sparse_visual_reference.h"
#include <io.h>

static int coalesce_pixels() try {
  using namespace winrt::Windows::Graphics::Capture;
  using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
  init_apartment(apartment_type::single_threaded);
  DispatcherQueueOptions options{sizeof(options),DQTYPE_THREAD_CURRENT,DQTAT_COM_STA};
  com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;
  check_hresult(CreateDispatcherQueueController(options,queue.put()));
  Compositor compositor;
  auto owner=foreground(compositor,256,256);
  auto reference=foreground_on_device(owner,compositor,256,256);
  auto candidate=foreground_on_device(owner,compositor,256,256);
  auto root=compositor.CreateContainerVisual();root.Size({640,320});
  for(unsigned side=0;side<2;++side)for(unsigned x=0;x<20;++x) {
    auto stripe=compositor.CreateSpriteVisual();stripe.Size({16,320});stripe.Offset({float(side*320+x*16),0,0});
    stripe.Brush(compositor.CreateColorBrush(winrt::Windows::UI::Color{255,uint8_t(20+x*11),uint8_t(170-x*7),uint8_t(40+x*8)}));
    root.Children().InsertAtTop(stripe);
  }
  root.Children().InsertAtTop(reference.visual);root.Children().InsertAtTop(candidate.visual);
  auto raw=compositor.CreateBackdropBrush();
  Blur blur;blur.sigma=8;blur.Source(CompositionEffectSourceParameter(L"backdrop"));
  auto blurred=compositor.CreateEffectFactory(blur).CreateBrush();blurred.SetSourceParameter(L"backdrop",raw);
  std::vector<viewflow::vfgp::AtlasPatch> original_patches;
  for(unsigned y=0;y<8;++y)for(unsigned x=0;x<8;++x)
    original_patches.push_back({0,16+x*28,16+y*28,16+x*28,16+y*28,28,28});
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice device{nullptr};
  auto dxgi=owner.d3d.as<IDXGIDevice>();
  check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(),reinterpret_cast<::IInspectable**>(put_abi(device))));
  auto pool=Direct3D11CaptureFramePool::CreateFreeThreaded(device,DirectXPixelFormat::B8G8R8A8UIntNormalized,2,{640,320});
  auto session=pool.CreateCaptureSession(GraphicsCaptureItem::CreateFromVisual(root));session.StartCapture();
  com_ptr<ID3D11DeviceContext> context;owner.d3d->GetImmediateContext(context.put());
  unsigned phase=0;
  for(float scale:{1.0f,0.75f,0.5f})for(float offset:{0.0f,0.25f})for(unsigned state:{0u,1u,0u,2u,3u,4u,5u}) {
    ++phase;
    auto patches=original_patches;
    if(state==3)std::swap(patches[62].x,patches[63].x);
    std::vector<uint8_t> alpha(256*256,255),bytes(256*256*4);
    const std::array<uint8_t,3> rgb{uint8_t(30+phase*6),uint8_t(220-phase*5),uint8_t(70+phase*3)};
    for(unsigned y=0;y<256;++y)for(unsigned x=0;x<256;++x) {
      const auto i=y*256+x;
      if(state==1 && x>=128)alpha[i]=128;
      if(state==2 && x>=64 && x<80 && y>=64 && y<80)alpha[i]=0;
      if(state>=4 && (x<72 || x>=184) && (y<72 || y>=184))
        alpha[i]=state==4?128:192;
      if(x>=24 && x<56 && y>=24 && y<56)alpha[i]=255;
      for(unsigned c=0;c<3;++c) {
        const unsigned value=(x>=24 && x<56 && y>=24 && y<56)?rgb[c]:unsigned(rgb[c])+((x+y+c*7)%25);
        bytes[i*4+c]=uint8_t(value*alpha[i]/255);
      }
      bytes[i*4+3]=alpha[i];
    }
    D3D11_TEXTURE2D_DESC desc{};desc.Width=256;desc.Height=256;desc.MipLevels=1;desc.ArraySize=1;
    desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_DEFAULT;
    desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
    D3D11_SUBRESOURCE_DATA data{bytes.data(),256*4,0};
    viewflow::windows::CompositedFrame frame;frame.frame_identity=phase;frame.width=256;frame.height=256;
    check_hresult(owner.d3d->CreateTexture2D(&desc,&data,frame.premultiplied_bgra.GetAddressOf()));
    auto surface=stage_gpu_surface(owner,compositor,frame);
    const auto flags=viewflow::windows_preview::OpaqueSparsePatches(alpha,256,256,patches);
    reference_commit_sparse_visuals(reference,reference_stage_sparse_visuals(reference,compositor,surface.surface,patches,0,256,256,blurred),256*scale,256*scale);
    commit_sparse_visuals(candidate,stage_sparse_visuals(candidate,compositor,surface.surface,patches,0,256,256,raw,8,flags),256*scale,256*scale);
    reference.visual.Offset({32+offset,32+offset,0});candidate.visual.Offset({352+offset,32+offset,0});
    size_t backgrounds=0;for(auto const& [key,node]:candidate.shared_sparse->nodes)if(node.background)++backgrounds;
    const auto merged=viewflow::windows_preview::CoalesceSparsePatches(patches,flags);
    if(backgrounds!=merged.patches.size()-std::count(merged.opaque.begin(),merged.opaque.end(),uint8_t(1)))throw std::runtime_error("coalescing was not applied");
    if(merged.patches.size()>=patches.size())throw std::runtime_error("no adjacent patches merged");
    if(state>=4 && backgrounds<4)throw std::runtime_error("multiple backdrop regions were not exercised");
    size_t mismatch=0;bool verified=false;
    const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    while(std::chrono::steady_clock::now()<until) {
      MSG msg{};while(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);}
      auto captured=pool.TryGetNextFrame();if(!captured){Sleep(5);continue;}
      auto access=captured.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
      com_ptr<ID3D11Texture2D> texture;check_hresult(access->GetInterface(guid_of<ID3D11Texture2D>(),texture.put_void()));
      D3D11_TEXTURE2D_DESC read_desc{};texture->GetDesc(&read_desc);read_desc.Usage=D3D11_USAGE_STAGING;
      read_desc.BindFlags=0;read_desc.MiscFlags=0;read_desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
      com_ptr<ID3D11Texture2D> readback;check_hresult(owner.d3d->CreateTexture2D(&read_desc,nullptr,readback.put()));
      context->CopyResource(readback.get(),texture.get());D3D11_MAPPED_SUBRESOURCE mapped{};
      check_hresult(context->Map(readback.get(),0,D3D11_MAP_READ,0,&mapped));
      mismatch=0;
      for(unsigned y=0;y<320;++y)for(unsigned x=0;x<320;++x)for(unsigned c=0;c<3;++c) {
        const auto* left=static_cast<const uint8_t*>(mapped.pData)+y*mapped.RowPitch+x*4;
        if(abs(int(left[c])-int(left[320*4+c]))>2)++mismatch;
      }
      const unsigned marker=32+unsigned(40*scale);
      const auto* sample=static_cast<const uint8_t*>(mapped.pData)+marker*mapped.RowPitch+marker*4;
      bool fresh=true;for(unsigned c=0;c<3;++c)if(abs(int(sample[c])-int(rgb[c]))>2)fresh=false;
      context->Unmap(readback.get(),0);captured.Close();
      if(fresh && mismatch==0){verified=true;break;}
    }
    std::printf("coalesce-pixels phase=%u scale=%.2f offset=%.2f state=%u backgrounds=%zu mismatches=%zu verified=%u\n",phase,scale,offset,state,backgrounds,mismatch,unsigned(verified));
    if(!verified)throw std::runtime_error("coalesce backdrop pixel mismatch or stale capture");
  }
  session.Close();pool.Close();return 0;
} catch(hresult_error const& error) {std::fprintf(stderr,"coalesce HRESULT=%08x\n",unsigned(error.code().value));return 2;}
catch(std::exception const& error) {std::fprintf(stderr,"%s\n",error.what());return 2;}

int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
  FILE* log=nullptr;if(_wfreopen_s(&log,L"coalesce-pixels-result.log",L"w",stdout)!=0)return 2;
  _dup2(_fileno(stdout),_fileno(stderr));setvbuf(stdout,nullptr,_IONBF,0);
  return coalesce_pixels();
}
