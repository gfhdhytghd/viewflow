#define NOMINMAX
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <d3d11.h>
#include <wmcodecdsp.h>
#include <comdef.h>
#include <iostream>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dxguid.lib")

static std::string utf8(const wchar_t* s) {
  if (!s) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
  std::string out(n ? n : 0, '\0');
  if (n) { WideCharToMultiByte(CP_UTF8, 0, s, -1, out.data(), n, nullptr, nullptr); out.resize(n - 1); }
  return out;
}

static std::string guid(const GUID& g) {
  wchar_t b[64]{};
  StringFromGUID2(g, b, ARRAYSIZE(b));
  return utf8(b);
}

static std::string subtype(IMFMediaType* t) {
  GUID g{};
  return SUCCEEDED(t->GetGUID(MF_MT_SUBTYPE, &g)) ? guid(g) : "<none>";
}

static void probe_d3d11() {
  IDXGIFactory1* factory = nullptr;
  HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
  if (FAILED(hr)) { std::cout << "d3d11_factory_hr=0x" << std::hex << hr << std::dec << "\n"; return; }
  std::vector<GUID> profiles = {D3D11_DECODER_PROFILE_H264_VLD_NOFGT, D3D11_DECODER_PROFILE_H264_VLD_FGT};
  const DXGI_FORMAT formats[] = {DXGI_FORMAT_NV12, DXGI_FORMAT_AYUV, DXGI_FORMAT_Y410, DXGI_FORMAT_Y416};
  const char* format_names[] = {"NV12", "AYUV(YUV444-8)", "Y410(YUV444-10)", "Y416(YUV444-16)"};
  for (UINT ai = 0;; ++ai) {
    IDXGIAdapter1* adapter = nullptr;
    if (factory->EnumAdapters1(ai, &adapter) == DXGI_ERROR_NOT_FOUND) break;
    DXGI_ADAPTER_DESC1 desc{}; adapter->GetDesc1(&desc);
    std::cout << "adapter[" << ai << "]: " << utf8(desc.Description) << "\n";
    ID3D11Device* dev = nullptr; ID3D11DeviceContext* ctx = nullptr;
    D3D_FEATURE_LEVEL fl{};
    hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                            nullptr, 0, D3D11_SDK_VERSION, &dev, &fl, &ctx);
    std::cout << "  create_device_hr=0x" << std::hex << hr << std::dec << " feature_level=0x" << std::hex << fl << std::dec << "\n";
    if (SUCCEEDED(hr)) {
      ID3D11VideoDevice* video = nullptr;
      hr = dev->QueryInterface(IID_PPV_ARGS(&video));
      std::cout << "  video_device=" << (SUCCEEDED(hr) ? "present" : "absent") << "\n";
      if (SUCCEEDED(hr)) {
        UINT count = video->GetVideoDecoderProfileCount();
        std::cout << "  decoder_profile_count=" << count << "\n";
        for (const GUID& profile : profiles) {
          bool present = false;
          for (UINT pi = 0; pi < count; ++pi) { GUID got{}; if (SUCCEEDED(video->GetVideoDecoderProfile(pi, &got)) && got == profile) present = true; }
          std::cout << "  profile=" << guid(profile) << " h264_vld_present=" << (present ? "true" : "false") << "\n";
          if (present) {
            for (size_t fi = 0; fi < ARRAYSIZE(formats); ++fi) {
              BOOL ok = FALSE; HRESULT fhr = video->CheckVideoDecoderFormat(&profile, formats[fi], &ok);
              std::cout << "    format=" << format_names[fi] << " hr=0x" << std::hex << fhr << std::dec << " supported=" << (ok ? "true" : "false") << "\n";
            }
          }
        }
        video->Release();
      }
      ctx->Release(); dev->Release();
    }
    adapter->Release();
  }
  factory->Release();
}

static bool list_types(IMFTransform* tr, bool input) {
  bool h264 = false;
  std::cout << (input ? "    input_types:\n" : "    output_types:\n");
  for (DWORD i = 0;; ++i) {
    IMFMediaType* t = nullptr;
    HRESULT hr = input ? tr->GetInputAvailableType(0, i, &t)
                       : tr->GetOutputAvailableType(0, i, &t);
    if (hr == MF_E_NO_MORE_TYPES) break;
    if (FAILED(hr)) { std::cout << "      <error 0x" << std::hex << hr << std::dec << ">\n"; break; }
    auto st = subtype(t); h264 = h264 || st == guid(MFVideoFormat_H264);
    std::cout << "      " << st << "\n";
    t->Release();
  }
  return h264;
}

int wmain() {
  HRESULT chr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(chr) && chr != RPC_E_CHANGED_MODE) { std::cerr << "CoInitializeEx failed\n"; return 2; }
  HRESULT hr = MFStartup(MF_VERSION);
  if (FAILED(hr)) { std::cerr << "MFStartup failed: 0x" << std::hex << hr << "\n"; if (SUCCEEDED(chr)) CoUninitialize(); return 2; }
  IMFActivate** acts = nullptr; UINT32 count = 0;
  MFT_REGISTER_TYPE_INFO in_info{MFMediaType_Video, MFVideoFormat_H264};
  hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
                 MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                 &in_info, nullptr, &acts, &count);
  std::cout << "query_input=H264\nresult=0x" << std::hex << hr << std::dec << "\ncount=" << count << "\n";
  if (SUCCEEDED(hr) && count == 0) {
    std::cout << "fallback_query=all_hardware_video_decoders\n";
    hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                   nullptr, nullptr, &acts, &count);
    std::cout << "fallback_result=0x" << std::hex << hr << std::dec << "\ncount=" << count << "\n";
  }
  if (SUCCEEDED(hr)) for (UINT32 i = 0; i < count; ++i) {
    WCHAR* name = nullptr; UINT32 cch = 0;
    acts[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &name, &cch);
    GUID clsid{}; acts[i]->GetGUID(MFT_TRANSFORM_CLSID_Attribute, &clsid);
    std::cout << "decoder[" << i << "]:\n"
              << "  friendly_name=" << utf8(name) << "\n"
              << "  clsid=" << guid(clsid) << "\n"
              << "  h264_profile=unknown (no H264 candidate; static enumeration cannot prove High444Predictive support)\n";
    if (name) CoTaskMemFree(name);
    IMFTransform* tr = nullptr;
    HRESULT ahr = acts[i]->ActivateObject(IID_PPV_ARGS(&tr));
    if (SUCCEEDED(ahr)) {
      UINT32 d3d = 0; HRESULT d3dhr = E_FAIL;
      IMFAttributes* attrs = nullptr;
      if (SUCCEEDED(tr->GetAttributes(&attrs))) { d3dhr = attrs->GetUINT32(MF_SA_D3D11_AWARE, &d3d); attrs->Release(); }
      std::cout << "  d3d11_aware=" << (SUCCEEDED(d3dhr) ? (d3d ? "true" : "false") : "unknown") << "\n";
      bool h264_input = list_types(tr, true); list_types(tr, false);
      std::cout << "  h264_input_type=" << (h264_input ? "present" : "not-listed") << "\n";
      IMFShutdown* shutdown = nullptr;
      if (SUCCEEDED(tr->QueryInterface(IID_PPV_ARGS(&shutdown)))) { shutdown->Shutdown(); shutdown->Release(); }
      tr->Release();
    }
    else std::cout << "  activate_hr=0x" << std::hex << ahr << std::dec << "\n";
    acts[i]->Release();
  }
  if (acts) CoTaskMemFree(acts);
  probe_d3d11();
  MFShutdown();
  if (SUCCEEDED(chr)) CoUninitialize();
  return SUCCEEDED(hr) ? 0 : 3;
}
