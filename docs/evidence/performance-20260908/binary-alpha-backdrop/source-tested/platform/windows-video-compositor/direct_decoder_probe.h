#pragma once
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <cstdio>
#include <chrono>

// Allocation-only diagnostic, no compressed input and no display changes.
inline HRESULT ProbeDirectDecoder(UINT width = 256, UINT height = 256) {
  using Microsoft::WRL::ComPtr;
  ComPtr<IDXGIFactory1> factory;
  HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
  if (FAILED(hr)) return hr;
  ComPtr<IDXGIAdapter1> adapter;
  hr = factory->EnumAdapters1(0, &adapter); if (FAILED(hr)) return hr;
  DXGI_ADAPTER_DESC1 desc{};
  hr = adapter->GetDesc1(&desc); if (FAILED(hr)) return hr;
  if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) return E_NOTIMPL;
  std::fprintf(stderr,"direct adapter vendor=%04x device=%04x\n",desc.VendorId,desc.DeviceId);
  std::fflush(stderr);
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  hr = D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,
      D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
      nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context);
  if (FAILED(hr)) return hr;
  ComPtr<ID3D11VideoDevice> video;
  hr = device.As(&video); if (FAILED(hr)) return hr;
  D3D11_VIDEO_DECODER_DESC decoderDesc{D3D11_DECODER_PROFILE_H264_VLD_NOFGT,width,height,DXGI_FORMAT_NV12};
  BOOL supported = FALSE;
  hr = video->CheckVideoDecoderFormat(&decoderDesc.Guid,decoderDesc.OutputFormat,&supported);
  if (FAILED(hr)) return hr;
  if (!supported) return E_NOTIMPL;
  UINT count{};
  hr = video->GetVideoDecoderConfigCount(&decoderDesc,&count);
  if (FAILED(hr)) return hr;
  if (!count || count > 1024) return E_FAIL;
  for (UINT i=0;i<count;++i) {
    D3D11_VIDEO_DECODER_CONFIG config{};
    hr = video->GetVideoDecoderConfig(&decoderDesc,i,&config);
    if (FAILED(hr)) return hr;
    if (config.ConfigBitstreamRaw != 2) continue;
    std::fprintf(stderr,"direct create begin config=%u raw=%u size=%ux%u\n",i,config.ConfigBitstreamRaw,width,height);
    std::fflush(stderr);
    ComPtr<ID3D11VideoDecoder> decoder;
    const auto started = std::chrono::steady_clock::now();
    hr = video->CreateVideoDecoder(&decoderDesc,&config,&decoder);
    const auto us = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-started).count();
    std::fprintf(stderr,"direct create finished hr=0x%08lx elapsed_us=%lld\n",static_cast<unsigned long>(hr),static_cast<long long>(us));
    std::fflush(stderr);
    return hr;
  }
  return E_NOTIMPL;
}
