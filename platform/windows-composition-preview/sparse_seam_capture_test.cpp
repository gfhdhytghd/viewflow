// Offscreen pixel oracle: one continuous image versus two packed atlas patches.
#define wmain viewflow_unused_preview_entry
#include "main.cpp"
#undef wmain

int wmain(int argc, wchar_t**) try {
  using namespace winrt::Windows::Graphics::Capture;
  using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
  init_apartment(apartment_type::single_threaded);
  DispatcherQueueOptions options{sizeof(options),DQTYPE_THREAD_CURRENT,DQTAT_COM_STA};
  com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;
  check_hresult(CreateDispatcherQueueController(options,queue.put()));
  Compositor compositor;
  auto owner=foreground(compositor,256,128);
  auto reference=foreground_on_device(owner,compositor,192,128);
  auto candidate=foreground_on_device(owner,compositor,192,128);
  auto root=compositor.CreateContainerVisual();root.Size({640,256});
  auto background=compositor.CreateSpriteVisual();background.Size({640,256});
  background.Brush(compositor.CreateColorBrush(winrt::Windows::UI::Color{255,220,20,150}));
  root.Children().InsertAtTop(background);
  root.Children().InsertAtTop(reference.visual);root.Children().InsertAtTop(candidate.visual);
  const std::vector<viewflow::vfgp::AtlasPatch> patches{
    {0,0,0,0,0,96,64},{0,96,0,128,0,96,64},
    {0,0,64,32,64,96,64},{0,96,64,160,64,96,64}};
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice device{nullptr};
  auto dxgi=owner.d3d.as<IDXGIDevice>();
  check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(),reinterpret_cast<::IInspectable**>(put_abi(device))));
  auto pool=Direct3D11CaptureFramePool::CreateFreeThreaded(device,DirectXPixelFormat::B8G8R8A8UIntNormalized,2,{640,256});
  auto capture=pool.CreateCaptureSession(GraphicsCaptureItem::CreateFromVisual(root));capture.StartCapture();
  com_ptr<ID3D11DeviceContext> context;owner.d3d->GetImmediateContext(context.put());
  auto surface=[&](uint32_t width,const std::vector<uint32_t>& pixels) {
    D3D11_TEXTURE2D_DESC desc{};desc.Width=width;desc.Height=128;desc.MipLevels=desc.ArraySize=1;
    desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_DEFAULT;
    desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
    D3D11_SUBRESOURCE_DATA data{pixels.data(),width*4,0};
    viewflow::windows::CompositedFrame frame;frame.frame_identity=1;frame.width=width;frame.height=128;
    check_hresult(owner.d3d->CreateTexture2D(&desc,&data,frame.premultiplied_bgra.GetAddressOf()));
    return stage_gpu_surface(owner,compositor,frame);
  };
  unsigned failed=0;
  for(unsigned mode=argc>1?0:4;mode<(argc>1?4:5);++mode) for(unsigned state=0;state<8;++state) {
    const float scale=state%4==0?1.0f:state%4==1?0.83f:state%4==2?1.17f:1.37f;
    const float offset=state%4==0?0.0f:0.25f;
    const unsigned alpha=state<4?255:128;
    const unsigned red=(45+state*20)*alpha/255;
    const uint32_t color=(alpha<<24)|(red<<16)|((100u*alpha/255)<<8)|(180u*alpha/255);
    std::vector<uint32_t> full(192*128,color),atlas(256*128,0);
    for(auto const& patch:patches)for(unsigned y=0;y<patch.height;++y)for(unsigned x=0;x<patch.width;++x)
      atlas[(patch.y+y)*256+patch.x+x]=color;
    auto original=surface(192,full),packed=surface(256,atlas);
    commit_gpu_surface(reference,std::move(original));reference.visual.Size({192*scale,128*scale});
    commit_sparse_visuals(candidate,stage_sparse_visuals(candidate,compositor,packed.surface,patches,0,192,128,nullptr),192*scale,128*scale);
    candidate.visual.Size({192*scale,128*scale});
    reference.visual.Offset({16+offset,16+offset,0});candidate.visual.Offset({336+offset,16+offset,0});
    if(mode<4) {
    candidate.sparse_root.BorderMode((mode&1)?CompositionBorderMode::Hard:CompositionBorderMode::Inherit);
    candidate.shared_sparse->brush.BitmapInterpolationMode((mode&2)?CompositionBitmapInterpolationMode::NearestNeighbor:CompositionBitmapInterpolationMode::Linear);
    }
    size_t mismatch=0;bool fresh=false;
    const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(1);
    while(std::chrono::steady_clock::now()<until) {
      MSG message{};while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE))DispatchMessageW(&message);
      auto captured=pool.TryGetNextFrame();if(!captured){Sleep(5);continue;}
      auto access=captured.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
      com_ptr<ID3D11Texture2D> texture;check_hresult(access->GetInterface(guid_of<ID3D11Texture2D>(),texture.put_void()));
      D3D11_TEXTURE2D_DESC desc{};texture->GetDesc(&desc);desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=desc.MiscFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
      com_ptr<ID3D11Texture2D> readback;check_hresult(owner.d3d->CreateTexture2D(&desc,nullptr,readback.put()));
      context->CopyResource(readback.get(),texture.get());D3D11_MAPPED_SUBRESOURCE mapped{};
      check_hresult(context->Map(readback.get(),0,D3D11_MAP_READ,0,&mapped));
      const auto* marker=static_cast<const uint8_t*>(mapped.pData)+32*mapped.RowPitch+32*4;
      fresh=abs(int(marker[2])-int(red+(220u*(255-alpha)+127)/255))<=2;
      mismatch=0;
      for(unsigned y=20;y<unsigned(16+128*scale)-4;++y)for(unsigned x=20;x<unsigned(16+192*scale)-4;++x) {
        const auto* left=static_cast<const uint8_t*>(mapped.pData)+y*mapped.RowPitch+x*4;
        bool different=false;for(unsigned c=0;c<3;++c)different|=abs(int(left[c])-int(left[320*4+c]))>2;
        mismatch+=different;
      }
      context->Unmap(readback.get(),0);captured.Close();
      if(fresh && mismatch==0)break;
    }
    std::printf("mode=%u alpha=%u scale=%.2f offset=%.2f fresh=%u seam_pixels=%zu\n",mode,alpha,scale,offset,unsigned(fresh),mismatch);std::fflush(stdout);
    if(!fresh || (mode>=2 && mismatch))++failed;
  }
  capture.Close();pool.Close();
  return failed?1:0;
} catch(winrt::hresult_error const& error){std::fprintf(stderr,"HRESULT=%08x stage=%s\n",unsigned(error.code()),stage);return 1;}
catch(std::exception const& error){std::fprintf(stderr,"%s\n",error.what());return 1;}
