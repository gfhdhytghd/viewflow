// Offscreen Direct2D diagnostic: preserves sigma, records GPU intervals and pixels.
// Measures neither HostBackdrop sampling nor DWM presentation or remote latency.
#include <windows.h>
#include <d3d11.h>
#define INITGUID
#include <initguid.h>
#include <d2d1_1.h>
#include <d2d1effects.h>
#include <dxgi1_2.h>
#include <winrt/base.h>
#include <array>
#include <vector>
#include <cstdio>
#include <string>
#include <cstring>
#include <stdexcept>
using winrt::com_ptr;
using winrt::check_hresult;
constexpr UINT width=3840,height=2160;
template<class T> void query(ID3D11DeviceContext* context,ID3D11Query* q,T& value) {
  const auto start=GetTickCount64();
  for(;;) {
    auto hr=context->GetData(q,&value,sizeof(value),0);
    if(hr==S_OK)return;
    check_hresult(hr);
    if(GetTickCount64()-start>10000)throw std::runtime_error("diagnostic GPU query timeout");
    Sleep(1);
  }
}
int wmain(int argc,wchar_t** argv) {
  FILE* log=nullptr;
  try {
    if(argc!=2)throw std::runtime_error("usage: probe output-prefix");
    const std::wstring prefix=argv[1];
    if(_wfopen_s(&log,(prefix+L".csv").c_str(),L"wb"))throw std::runtime_error("open log");
    com_ptr<IDXGIFactory1> factory;
    check_hresult(CreateDXGIFactory1(__uuidof(IDXGIFactory1),factory.put_void()));
    com_ptr<IDXGIAdapter1> adapter;
    for(UINT i=0;;++i) {
      com_ptr<IDXGIAdapter1> a;
      check_hresult(factory->EnumAdapters1(i,a.put()));
      DXGI_ADAPTER_DESC1 desc{};check_hresult(a->GetDesc1(&desc));
      if(desc.VendorId==0x8086 && !(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)) {
        adapter=a;
        fprintf(log,"# adapter_vendor=%u device=%u luid_low=%u luid_high=%ld width=%u height=%u sigma=12 border=hard cached=0 invalidate=1\n",desc.VendorId,desc.DeviceId,desc.AdapterLuid.LowPart,desc.AdapterLuid.HighPart,width,height);
        break;
      }
    }
    com_ptr<ID3D11Device> device;com_ptr<ID3D11DeviceContext> context;
    check_hresult(D3D11CreateDevice(adapter.get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,device.put(),nullptr,context.put()));
    auto dxgi=device.as<IDXGIDevice>();com_ptr<ID2D1Device> d2d;
    check_hresult(D2D1CreateDevice(dxgi.get(),nullptr,d2d.put()));
    com_ptr<ID2D1DeviceContext> draw;check_hresult(d2d->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE,draw.put()));
    std::vector<uint32_t> pixels(size_t(width)*height);
    for(UINT y=0;y<height;++y)for(UINT x=0;x<width;++x) {
      UINT r=(x/7+y/11)%2?240:16,g=(x*255)/(width-1),b=(y*255)/(height-1);
      if((x%127)<2 || (y%113)<2)r=g=b=255;
      pixels[size_t(y)*width+x]=0xff000000u|(r<<16)|(g<<8)|b;
    }
    const auto format=D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED);
    com_ptr<ID2D1Bitmap1> input;
    check_hresult(draw->CreateBitmap(D2D1::SizeU(width,height),pixels.data(),width*4,D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_NONE,format),input.put()));
    D3D11_TEXTURE2D_DESC desc{};desc.Width=width;desc.Height=height;desc.MipLevels=desc.ArraySize=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
    com_ptr<ID3D11Texture2D> target;check_hresult(device->CreateTexture2D(&desc,nullptr,target.put()));
    auto surface=target.as<IDXGISurface>();com_ptr<ID2D1Bitmap1> output;
    auto props=D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET|D2D1_BITMAP_OPTIONS_CANNOT_DRAW,format);
    check_hresult(draw->CreateBitmapFromDxgiSurface(surface.get(),&props,output.put()));draw->SetTarget(output.get());
    std::array<com_ptr<ID2D1Effect>,3> effects;
    for(UINT i=0;i<effects.size();++i) {
      check_hresult(draw->CreateEffect(CLSID_D2D1GaussianBlur,effects[i].put()));
      check_hresult(effects[i]->SetValue(D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION,12.0f));
      check_hresult(effects[i]->SetValue(D2D1_GAUSSIANBLUR_PROP_OPTIMIZATION,i));
      check_hresult(effects[i]->SetValue(D2D1_GAUSSIANBLUR_PROP_BORDER_MODE,D2D1_BORDER_MODE_HARD));
      check_hresult(effects[i]->SetValue(D2D1_PROPERTY_CACHED,FALSE));
    }
    com_ptr<ID3D11Query> disjoint,start,end;
    D3D11_QUERY_DESC q{D3D11_QUERY_TIMESTAMP_DISJOINT,0};check_hresult(device->CreateQuery(&q,disjoint.put()));
    q.Query=D3D11_QUERY_TIMESTAMP;check_hresult(device->CreateQuery(&q,start.put()));check_hresult(device->CreateQuery(&q,end.put()));
    fprintf(log,"block,sample,mode,frequency,disjoint,gpu_ms\n");
    // Each mode occurs early and late; first ten samples per block are warmup.
    constexpr UINT modes[]={1,0,2,2,0,1};
    for(UINT block=0;block<6;++block)for(UINT sample=0;sample<70;++sample) {
      const auto mode=modes[block];auto effect=effects[mode].get();effect->SetInput(0,input.get(),TRUE);
      context->Begin(disjoint.get());context->End(start.get());
      draw->BeginDraw();draw->Clear(D2D1::ColorF(0,0));
      draw->DrawImage(effect,D2D1::Point2F(),D2D1::RectF(0,0,float(width),float(height)));
      check_hresult(draw->EndDraw());
      context->End(end.get());context->End(disjoint.get());context->Flush();
      D3D11_QUERY_DATA_TIMESTAMP_DISJOINT d{};UINT64 s{},e{};
      query(context.get(),disjoint.get(),d);query(context.get(),start.get(),s);query(context.get(),end.get(),e);
      if(e<s || !d.Frequency)throw std::runtime_error("invalid GPU timestamp");
      fprintf(log,"%u,%u,%u,%llu,%u,%.9f\n",block,sample,mode,d.Frequency,unsigned(d.Disjoint),double(e-s)*1000/d.Frequency);
      if(sample==69 && block<3) {
        desc.BindFlags=0;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        com_ptr<ID3D11Texture2D> staging;check_hresult(device->CreateTexture2D(&desc,nullptr,staging.put()));
        context->CopyResource(staging.get(),target.get());D3D11_MAPPED_SUBRESOURCE mapped{};
        check_hresult(context->Map(staging.get(),0,D3D11_MAP_READ,0,&mapped));
        FILE* image=nullptr;
        if(_wfopen_s(&image,(prefix+L"-mode"+std::to_wstring(mode)+L".bgra").c_str(),L"wb")) {context->Unmap(staging.get(),0);throw std::runtime_error("open pixels");}
        bool ok=true;
        for(UINT y=0;y<height;++y)ok&=fwrite(static_cast<const char*>(mapped.pData)+size_t(y)*mapped.RowPitch,4,width,image)==width;
        ok&=fclose(image)==0;context->Unmap(staging.get(),0);
        if(!ok)throw std::runtime_error("write pixels");
      }
    }
    fprintf(log,"# exit=0\n");fclose(log);return 0;
  } catch(winrt::hresult_error const& e) {if(log){fprintf(log,"# HRESULT=%08x\n",unsigned(e.code()));fclose(log);}return 1;}
    catch(std::exception const& e) {if(log){fprintf(log,"# error=%s\n",e.what());fclose(log);}return 2;}
}
