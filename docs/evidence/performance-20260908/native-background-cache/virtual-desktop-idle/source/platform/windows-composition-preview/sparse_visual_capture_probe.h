#pragma once
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
// Capture only this test's own visual tree, never a window or monitor.
inline void verify_shared_sparse_pixels(Compositor const& compositor, Foreground& owner) {
  using namespace winrt::Windows::Graphics::Capture;
  using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice device{nullptr};
  auto dxgi=owner.d3d.as<IDXGIDevice>();
  check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(),reinterpret_cast<::IInspectable**>(put_abi(device))));
  com_ptr<ID3D11DeviceContext> context;owner.d3d->GetImmediateContext(context.put());
  bool any_failed=false;
  for(unsigned variant=0;variant<15;++variant) {
    std::vector<uint8_t> bytes(512*256*4);
    for(unsigned y=0;y<256;++y)for(unsigned x=0;x<512;++x) {
      const auto i=(y*512+x)*4;const uint8_t alpha=(x%31==0 || y%29==0)?128:255;
      bytes[i]=uint8_t(((x+(std::min)(variant,5u)*37)%256)*unsigned(alpha)/255);
      bytes[i+1]=uint8_t(((y+(std::min)(variant,5u)*53)%256)*unsigned(alpha)/255);
      bytes[i+2]=uint8_t(180*unsigned(alpha)/255);bytes[i+3]=alpha;
    }
    D3D11_TEXTURE2D_DESC desc{};desc.Width=512;desc.Height=256;desc.MipLevels=1;desc.ArraySize=1;
    desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_DEFAULT;
    desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
    D3D11_SUBRESOURCE_DATA data{bytes.data(),512*4,0};
    viewflow::windows::CompositedFrame frame;frame.frame_identity=variant+1;frame.width=512;frame.height=256;
    check_hresult(owner.d3d->CreateTexture2D(&desc,&data,frame.premultiplied_bgra.GetAddressOf()));
    auto surface=stage_gpu_surface(owner,compositor,frame);
    std::vector<viewflow::vfgp::AtlasPatch> patches{{0,0,0,128,128,128,128},{0,128,0,0,0,80,96},
      {0,0,128,384,0,96,128},{0,128,128,256,128,128,80}};
    const auto original_patches=patches;
    if(variant==1)patches.erase(patches.begin()+1);
    auto proxy=foreground_on_device(owner,compositor,256,256);
    CompositionBrush backdrop=nullptr;
    if(variant==3)backdrop=compositor.CreateColorBrush(winrt::Windows::UI::Color{255,15,61,130});
    if(variant>=5) {
      Blur effect;effect.sigma=8;
      effect.Source(CompositionEffectSourceParameter(L"backdrop"));
      auto blurred=compositor.CreateEffectFactory(effect).CreateBrush();
      blurred.SetSourceParameter(L"backdrop",compositor.CreateBackdropBrush());
      backdrop=blurred;
    }
    auto current=reference_stage_sparse_visuals(proxy,compositor,surface.surface,patches,0,256,256,backdrop);
    reference_commit_sparse_visuals(proxy,std::move(current),256,256);
    CompositionBrush prototype_backdrop=backdrop;
    if(variant>=5)prototype_backdrop=compositor.CreateBackdropBrush();
    float active_sigma=variant>=5?8.0f:0.0f;
    auto production=foreground_on_device(owner,compositor,256,256);
    commit_sparse_visuals(production,stage_sparse_visuals(production,compositor,surface.surface,patches,0,256,256,prototype_backdrop,active_sigma),256,256);
    auto shared=[&]() -> SharedSparseScene& { return production.shared_sparse.value(); };
    if(variant==6) {
      auto reference=foreground_on_device(owner,compositor,256,256);
      auto reference_candidate=reference_stage_sparse_visuals(reference,compositor,surface.surface,patches,0,256,256,backdrop);
      reference_commit_sparse_visuals(reference,std::move(reference_candidate),256,256);
      shared().root.Children().RemoveAll();shared().root.Children().InsertAtTop(reference.visual);
    }
    production.visual.Offset({256,0,0});
    if(variant==2){proxy.visual.Scale({0.5f,0.5f,1});production.visual.Scale({0.5f,0.5f,1});}
    std::optional<Foreground> independent_reference;
    std::optional<SharedSparseScene> independent_scene;
    if(variant==11) {
      independent_reference=foreground_on_device(owner,compositor,256,256);
      reference_commit_sparse_visuals(*independent_reference,reference_stage_sparse_visuals(*independent_reference,compositor,surface.surface,patches,0,256,256,backdrop),256,256);
      independent_reference->visual.Offset({512,0,0});
      independent_scene=make_shared_sparse_scene(compositor,surface.surface,patches,prototype_backdrop,8.0f);
      independent_scene->root.Size({256,256});independent_scene->root.Offset({768,0,0});
      if(independent_scene->brush==shared().brush)throw std::runtime_error("proxy brush alias");
    }
    const int capture_width=variant==11?1024:512;
    auto root=compositor.CreateContainerVisual();root.Size({float(capture_width),256});
    if(variant>=5)for(unsigned side=0;side<(variant==11?4u:2u);++side)for(unsigned column=0;column<8;++column) {
      auto stripe=compositor.CreateSpriteVisual();stripe.Size({32,256});stripe.Offset({float(side*256+column*32),0,0});
      stripe.Brush(compositor.CreateColorBrush(winrt::Windows::UI::Color{255,uint8_t(30+column*25),90,uint8_t(230-column*20)}));
      root.Children().InsertAtTop(stripe);
    }
    root.Children().InsertAtTop(proxy.visual);root.Children().InsertAtTop(production.visual);
    if(independent_scene) {
      root.Children().InsertAtTop(independent_reference->visual);
      root.Children().InsertAtTop(independent_scene->root);
    }
    auto item=GraphicsCaptureItem::CreateFromVisual(root);
    auto pool=Direct3D11CaptureFramePool::CreateFreeThreaded(device,DirectXPixelFormat::B8G8R8A8UIntNormalized,2,{capture_width,256});
    auto session=pool.CreateCaptureSession(item);session.StartCapture();
    bool verified=false;size_t mismatches=0,nonzero=0;
    unsigned replacements=0;
    std::optional<std::array<uint8_t,4>> expected_marker;
    const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while(std::chrono::steady_clock::now()<until) {
      MSG message{};while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}
      auto captured=pool.TryGetNextFrame();
      if(!captured){Sleep(5);continue;}
      auto access=captured.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
      com_ptr<ID3D11Texture2D> texture;check_hresult(access->GetInterface(guid_of<ID3D11Texture2D>(),texture.put_void()));
      D3D11_TEXTURE2D_DESC read_desc{};texture->GetDesc(&read_desc);
      read_desc.Usage=D3D11_USAGE_STAGING;read_desc.BindFlags=0;read_desc.MiscFlags=0;read_desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
      com_ptr<ID3D11Texture2D> readback;check_hresult(owner.d3d->CreateTexture2D(&read_desc,nullptr,readback.put()));
      context->CopyResource(readback.get(),texture.get());D3D11_MAPPED_SUBRESOURCE mapped{};
      check_hresult(context->Map(readback.get(),0,D3D11_MAP_READ,0,&mapped));
      mismatches=0;nonzero=0;
      for(unsigned pair=0;pair<(variant==11?2u:1u);++pair)
      for(unsigned y=0;y<256;++y)for(unsigned x=0;x<256;++x) {
        const auto* left=static_cast<const uint8_t*>(mapped.pData)+y*mapped.RowPitch+(pair*512+x)*4;
        const auto* right=left+256*4;
        if(left[3])++nonzero;
        for(unsigned c=0;c<4;++c)if(abs(int(left[c])-int(right[c]))>1)++mismatches;
      }
      bool marker_current=true;
      if(expected_marker) {
        const auto* sample=static_cast<const uint8_t*>(mapped.pData)+16*mapped.RowPitch+16*4;
        for(unsigned c=0;c<4;++c)if(abs(int(sample[c])-int((*expected_marker)[c]))>1)marker_current=false;
      }
      context->Unmap(readback.get(),0);captured.Close();
      if(nonzero>500 && mismatches==0 && marker_current) {
        if((variant==4 || variant>=7) && replacements<6) {
          ++replacements;
          if(variant>=12){std::printf("transition-start variant=%u replacement=%u\n",variant,replacements);std::fflush(stdout);}
          expected_marker=std::array<uint8_t,4>{uint8_t(20+replacements*23),uint8_t(30+replacements*17),uint8_t(190-replacements*19),255};
          if(variant==9)desc.Width=replacements%2?1024:512;
          bytes.resize(size_t(desc.Width)*desc.Height*4);
          data.pSysMem=bytes.data();data.SysMemPitch=desc.Width*4;
          for(size_t i=0;i<bytes.size();i+=4)std::copy(expected_marker->begin(),expected_marker->end(),bytes.begin()+i);
          if(variant>=7 && !(variant==13 && replacements%2))for(unsigned y=0;y<desc.Height;++y)for(unsigned x=0;x<desc.Width;++x) {
            const auto i=(y*desc.Width+x)*4;
            const uint8_t alpha=(x%128==16 && y%128==16)?255:uint8_t(((x/16+y/16+replacements)%3)*127);
            for(unsigned c=0;c<3;++c)bytes[i+c]=uint8_t(unsigned((*expected_marker)[c])*alpha/255);
            bytes[i+3]=alpha;
          }
          viewflow::windows::CompositedFrame replacement;
          replacement.frame_identity=10+replacements;replacement.width=desc.Width;replacement.height=desc.Height;
          check_hresult(owner.d3d->CreateTexture2D(&desc,&data,replacement.premultiplied_bgra.GetAddressOf()));
          auto next_surface=stage_gpu_surface(owner,compositor,replacement);
          if(variant==13 && replacements%2) {
            commit_gpu_surface(proxy,stage_gpu_surface(proxy,compositor,replacement));
            commit_gpu_surface(production,stage_gpu_surface(production,compositor,replacement));
            if(production.shared_sparse || !production.shared_patches.empty() || production.sparse_root || production.visual.Children().Count())
              throw std::runtime_error("dense transition retained sparse state");
            surface=std::move(next_surface);
            continue;
          }
          ContainerVisual unchanged=nullptr;
          if(production.shared_sparse && !shared().order.empty())unchanged=shared().nodes.at(shared().order.front()).clip;
          size_t expected_created=0;
          if(variant==8) {
            if(replacements==1)patches.erase(patches.begin()+1);
            if(replacements==2){patches.insert(patches.begin()+1,{0,128,0,0,0,80,96});expected_created=1;}
            if(replacements==3){patches.back().width=64;expected_created=1;}
            if(replacements==4){patches.back().x=320;expected_created=0;}
            if(replacements==5)std::swap(patches[1],patches[2]);
            if(replacements==6){patches.back().height=64;expected_created=1;}
          }
          if(variant==14) {
            patches=original_patches;
            if(replacements%2)patches.erase(patches.begin()+1);
            for(size_t i=0;i<patches.size();++i){patches[i].x=uint32_t(i)*128;patches[i].y=0;}
            expected_created=replacements%2?0:1;
          }
          if(variant==9) {
            patches.back().x=replacements%2?768:256;
            expected_created=0;
          }
          if(variant==10) {
            patches=replacements%2?std::vector<viewflow::vfgp::AtlasPatch>{}:original_patches;
            expected_created=patches.size();
            if(patches.empty())expected_marker=std::array<uint8_t,4>{230,90,30,255};
          }
          if(variant==12 && replacements<=5) {
            if(replacements==1)active_sigma=4;
            if(replacements==2)prototype_backdrop=compositor.CreateBackdropBrush();
            if(replacements==3)active_sigma=0;
            if(replacements==4)prototype_backdrop=nullptr;
            if(replacements==5){prototype_backdrop=compositor.CreateBackdropBrush();active_sigma=12;}
            backdrop=nullptr;
            if(prototype_backdrop) {
              {
                Blur effect;effect.sigma=active_sigma;effect.Source(CompositionEffectSourceParameter(L"backdrop"));
                auto brush=compositor.CreateEffectFactory(effect).CreateBrush();
                brush.SetSourceParameter(L"backdrop",prototype_backdrop);backdrop=brush;
              }
            }
            // The frozen reference cache predates configuration-aware reuse.
            // Force its independent rebuild for the new requested appearance.
            proxy.sparse_root=nullptr;
            expected_created=patches.size();
          }
          if(variant==13)expected_created=patches.size();
          if(variant==11) {
            auto abandoned_layout=patches;abandoned_layout.back().width=32;
            auto old_surface=shared().brush.Surface();
            auto old_children=shared().root.Children().Count();
            auto old_node=shared().nodes.at(shared().order.back()).clip;
            {
              auto abandoned=stage_shared_sparse_visuals(shared(),next_surface.surface,abandoned_layout);
              if(abandoned.created!=1)throw std::runtime_error("abandoned plan did not create changed node");
              auto repacked=patches;repacked.back().x=320;
              auto before_offset=shared().nodes.at(shared().order.back()).pixels.Offset();
              auto abandoned_repack=stage_shared_sparse_visuals(shared(),next_surface.surface,repacked);
              if(abandoned_repack.created!=0 || abandoned_repack.retargeted!=1 ||
                  shared().nodes.at(shared().order.back()).pixels.Offset()!=before_offset)
                throw std::runtime_error("staging retarget changed visible pixels");
            }
            if(shared().brush.Surface()!=old_surface || shared().root.Children().Count()!=old_children || shared().nodes.at(shared().order.back()).clip!=old_node)
              throw std::runtime_error("staging changed active scene");
          }
          auto next=reference_stage_sparse_visuals(proxy,compositor,next_surface.surface,patches,0,256,256,backdrop);
          if(variant<8 && !next.reuse)throw std::runtime_error("surface replacement rebuilt patch descriptors");
          reference_commit_sparse_visuals(proxy,std::move(next),256,256);
          auto independent_surface=independent_scene?independent_scene->brush.Surface():nullptr;
          auto production_next=stage_sparse_visuals(production,compositor,next_surface.surface,patches,0,256,256,prototype_backdrop,active_sigma);
          const auto created=production_next.plan?production_next.plan->created:
              (production_next.replacement?production_next.replacement->nodes.size():0);
          if(variant==14 && (!production_next.plan || production_next.plan->retargeted==0))
            throw std::runtime_error("repacking did not retarget retained nodes");
          if(variant<8 && !production_next.reuse)throw std::runtime_error("production unchanged layout rebuilt");
          commit_sparse_visuals(production,std::move(production_next),256,256);
          if(independent_scene && independent_scene->brush.Surface()!=independent_surface)
            throw std::runtime_error("updating one proxy changed another surface");
          if(variant>=8 && (created!=expected_created || ((variant==8 || variant==14) && shared().nodes.at(shared().order.front()).clip!=unchanged)))
            throw std::runtime_error("incremental sparse visual reuse mismatch");
          surface=std::move(next_surface);
        } else {verified=true;break;}
      }
      Sleep(5);
    }
    session.Close();pool.Close();
    std::printf("own-visual-pixels variant=%u replacements=%u nonzero=%zu mismatched_channels=%zu verified=%u\n",variant,replacements,nonzero,mismatches,unsigned(verified));
    any_failed = any_failed || !verified;
  }
  if(any_failed)throw std::runtime_error("shared crop differs from production visual or capture unavailable");
}
