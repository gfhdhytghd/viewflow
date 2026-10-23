#pragma once

bool direct_composition_output_enabled() {
  static const bool enabled=[] {
    wchar_t value[2]{};
    return GetEnvironmentVariableW(L"VIEWFLOW_ATLAS_DIRECT_OUTPUT",value,2)==1 && value[0]==L'1';
  }();
  return enabled;
}

struct DirectDrawingLease {
  CompositionDrawingSurface surface{nullptr};
  com_ptr<ABI::Windows::UI::Composition::ICompositionDrawingSurfaceInterop> drawing;
  com_ptr<ID3D11Device> device;
  bool open{};
  HRESULT Close() {
    if(!open)return S_OK;
    open=false;
    const auto hr=drawing->EndDraw();
    com_ptr<ID3D11DeviceContext> context;device->GetImmediateContext(context.put());
    context->Flush();
    return FAILED(hr)?hr:device->GetDeviceRemovedReason();
  }
  ~DirectDrawingLease(){if(open)Close();}
};

viewflow::windows::DrawingTargetFactory direct_drawing_factory(
    CompositionGraphicsDevice const& graphics, ID3D11Device* device) {
  winrt::agile_ref<CompositionGraphicsDevice> shared_graphics{graphics};
  com_ptr<ID3D11Device> owned_device;owned_device.copy_from(device);
  return [shared_graphics,owned_device](uint64_t,uint32_t width,uint32_t height,
      ::IUnknown* spare,viewflow::windows::DrawingTarget* output) noexcept -> HRESULT {
    try {
      if(!output)return E_POINTER;
      auto lease=std::make_shared<DirectDrawingLease>();lease->device=owned_device;
      if(spare) {
        com_ptr<::IUnknown> value;value.copy_from(spare);
        lease->surface=value.as<CompositionDrawingSurface>();
        const auto size=lease->surface.Size();
        if(size.Width!=float(width)||size.Height!=float(height))lease->surface=nullptr;
      }
      if(!lease->surface)lease->surface=shared_graphics.get().CreateDrawingSurface(
          {float(width),float(height)},
          winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,
          winrt::Windows::Graphics::DirectX::DirectXAlphaMode::Premultiplied);
      lease->drawing=lease->surface.as<ABI::Windows::UI::Composition::ICompositionDrawingSurfaceInterop>();
      com_ptr<ID3D11Texture2D> texture;POINT offset{};
      check_hresult(lease->drawing->BeginDraw(nullptr,__uuidof(ID3D11Texture2D),texture.put_void(),&offset));
      lease->open=true;
      if(offset.x<0||offset.y<0)return E_INVALIDARG;
      output->texture=texture.get();output->x=UINT(offset.x);output->y=UINT(offset.y);
      output->presentation_surface=lease->surface.as<::IUnknown>().get();
      output->finish=[lease]{return lease->Close();};
      return S_OK;
    } catch (...) {return winrt::to_hresult();}
  };
}
