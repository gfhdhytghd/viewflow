#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wmcodecdsp.h>

#include <algorithm>
#include <array>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <cstring>
#include <vector>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

namespace {

template <typename T> void release(T*& object) { if (object) { object->Release(); object = nullptr; } }
std::string hr(HRESULT value) { std::ostringstream out; out << "0x" << std::hex << static_cast<unsigned long>(value); return out.str(); }
std::string guid(const GUID& value) { wchar_t text[64]{}; StringFromGUID2(value, text, ARRAYSIZE(text)); char utf8[128]{}; WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8, ARRAYSIZE(utf8), nullptr, nullptr); return utf8; }
std::string format_name(DXGI_FORMAT format) { switch (format) { case DXGI_FORMAT_NV12: return "NV12"; case DXGI_FORMAT_AYUV: return "AYUV"; default: return "DXGI_FORMAT_" + std::to_string(static_cast<unsigned>(format)); } }

bool read_file(const std::filesystem::path& path, std::vector<uint8_t>* bytes) {
  std::ifstream input(path, std::ios::binary);
  if (!input) return false;
  input.seekg(0, std::ios::end); const auto size = input.tellg(); input.seekg(0);
  if (size <= 0) return false;
  bytes->resize(static_cast<size_t>(size));
  input.read(reinterpret_cast<char*>(bytes->data()), size);
  return input.good();
}

struct Device { ID3D11Device* device{}; ID3D11DeviceContext* context{}; IMFDXGIDeviceManager* manager{}; UINT token{}; ~Device() { release(manager); release(context); release(device); } };

HRESULT create_device(Device* out) {
  IDXGIFactory1* factory = nullptr;
  HRESULT result = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
  if (FAILED(result)) return result;
  for (UINT index = 0; ; ++index) {
    IDXGIAdapter1* adapter = nullptr;
    if (factory->EnumAdapters1(index, &adapter) == DXGI_ERROR_NOT_FOUND) break;
    DXGI_ADAPTER_DESC1 description{}; adapter->GetDesc1(&description);
    if ((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) == 0) {
      D3D_FEATURE_LEVEL level{};
      result = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                                 nullptr, 0, D3D11_SDK_VERSION, &out->device, &level, &out->context);
      std::cout << "adapter="; std::wcout << description.Description; std::cout << " d3d11_hr=" << hr(result) << "\n";
      if (SUCCEEDED(result)) break;
    }
    release(adapter);
  }
  release(factory);
  if (FAILED(result) || !out->device) return FAILED(result) ? result : E_FAIL;
  result = MFCreateDXGIDeviceManager(&out->token, &out->manager);
  if (SUCCEEDED(result)) result = out->manager->ResetDevice(out->device, out->token);
  return result;
}

struct DecodeResult { bool all_gpu = true; bool any_gpu = false; std::vector<uint8_t> luma; UINT frames{}; GUID subtype{}; };

HRESULT set_output_type(IMFTransform* decoder, const char* label) {
  HRESULT last = MF_E_NO_MORE_TYPES;
  for (DWORD index = 0; last == MF_E_NO_MORE_TYPES || SUCCEEDED(last); ++index) {
    IMFMediaType* output = nullptr;
    last = decoder->GetOutputAvailableType(0, index, &output);
    if (last == MF_E_NO_MORE_TYPES) break;
    if (FAILED(last)) { std::cout << label << " output_type[" << index << "] hr=" << hr(last) << "\n"; break; }
    GUID subtype{}; output->GetGUID(MF_MT_SUBTYPE, &subtype);
    const HRESULT set = decoder->SetOutputType(0, output, 0);
    std::cout << label << " output_type[" << index << "]=" << guid(subtype) << " set_hr=" << hr(set) << "\n";
    release(output);
    if (SUCCEEDED(set)) return S_OK;
  }
  return FAILED(last) ? last : MF_E_INVALIDMEDIATYPE;
}

HRESULT configure(IMFTransform* decoder, Device& device, uint32_t profile, const char* label) {
  IMFAttributes* attributes = nullptr;
  HRESULT result = decoder->GetAttributes(&attributes);
  UINT32 aware = 0;
  if (SUCCEEDED(result)) {
    const HRESULT aware_hr = attributes->GetUINT32(MF_SA_D3D11_AWARE, &aware);
    attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
    std::cout << label << " mf_sa_d3d11_aware=" << (SUCCEEDED(aware_hr) ? std::to_string(aware) : "unavailable(" + hr(aware_hr) + ")") << "\n";
    release(attributes);
  }
  result = decoder->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, reinterpret_cast<ULONG_PTR>(device.manager));
  std::cout << label << " set_d3d_manager_hr=" << hr(result) << "\n";
  if (FAILED(result)) return result;
  IMFMediaType* input = nullptr;
  result = MFCreateMediaType(&input);
  if (SUCCEEDED(result)) result = input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(result)) result = input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  if (SUCCEEDED(result)) result = MFSetAttributeSize(input, MF_MT_FRAME_SIZE, 256, 256);
  if (SUCCEEDED(result)) result = MFSetAttributeRatio(input, MF_MT_FRAME_RATE, 30, 1);
  if (SUCCEEDED(result)) result = input->SetUINT32(MF_MT_MPEG2_PROFILE, profile);
  if (SUCCEEDED(result)) result = input->SetUINT32(MF_MT_MPEG2_LEVEL, 21);
  if (SUCCEEDED(result)) result = decoder->SetInputType(0, input, 0);
  std::cout << label << " set_input_h264_profile=" << profile << " hr=" << hr(result) << "\n";
  release(input);
  if (FAILED(result)) return result;
  return set_output_type(decoder, label);
}

void report_current_types(IMFTransform* decoder, const char* label) {
  IMFMediaType* input = nullptr; IMFMediaType* output = nullptr;
  const HRESULT input_hr = decoder->GetInputCurrentType(0, &input);
  const HRESULT output_hr = decoder->GetOutputCurrentType(0, &output);
  auto report = [&](const char* direction, HRESULT call, IMFMediaType* type) {
    GUID subtype{}; UINT32 profile = 0;
    if (SUCCEEDED(call)) type->GetGUID(MF_MT_SUBTYPE, &subtype);
    const HRESULT profile_hr = SUCCEEDED(call) ? type->GetUINT32(MF_MT_MPEG2_PROFILE, &profile) : call;
    std::cout << label << " negotiated_" << direction << "_hr=" << hr(call)
              << " subtype=" << (SUCCEEDED(call) ? guid(subtype) : "<none>")
              << " profile=" << (SUCCEEDED(profile_hr) ? std::to_string(profile) : "unavailable(" + hr(profile_hr) + ")") << "\n";
  };
  report("input", input_hr, input); report("output", output_hr, output);
  release(input); release(output);
}

HRESULT append_luma(ID3D11Texture2D* texture, UINT subresource, Device& device, DecodeResult* result) {
  D3D11_TEXTURE2D_DESC source{}; texture->GetDesc(&source);
  if (source.Format != DXGI_FORMAT_NV12 && source.Format != DXGI_FORMAT_AYUV) return MF_E_INVALIDMEDIATYPE;
  D3D11_TEXTURE2D_DESC staging = source;
  staging.Usage = D3D11_USAGE_STAGING; staging.BindFlags = 0; staging.CPUAccessFlags = D3D11_CPU_ACCESS_READ; staging.MiscFlags = 0;
  ID3D11Texture2D* copy = nullptr;
  HRESULT call = device.device->CreateTexture2D(&staging, nullptr, &copy);
  if (FAILED(call)) return call;
  device.context->CopySubresourceRegion(copy, 0, 0, 0, 0, texture, subresource, nullptr);
  D3D11_MAPPED_SUBRESOURCE mapped{};
  call = device.context->Map(copy, 0, D3D11_MAP_READ, 0, &mapped);
  if (SUCCEEDED(call)) {
    for (UINT y = 0; y < source.Height; ++y) {
      const uint8_t* row = static_cast<const uint8_t*>(mapped.pData) + y * mapped.RowPitch;
      for (UINT x = 0; x < source.Width; ++x) result->luma.push_back(source.Format == DXGI_FORMAT_NV12 ? row[x] : row[x * 4 + 2]);
    }
    device.context->Unmap(copy, 0);
  }
  release(copy);
  return call;
}

HRESULT drain_output(IMFTransform* decoder, Device& device, const char* label, bool collect_luma, DecodeResult* result) {
  for (;;) {
    MFT_OUTPUT_STREAM_INFO info{};
    HRESULT call = decoder->GetOutputStreamInfo(0, &info);
    if (FAILED(call)) { std::cout << label << " process_output_hr=" << hr(call) << "\n"; return call; }
    std::cout << label << " output_stream_flags=0x" << std::hex << info.dwFlags << std::dec << " cb_size=" << info.cbSize << "\n";
    MFT_OUTPUT_DATA_BUFFER output{}; DWORD status = 0;
    if ((info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) == 0) {
      IMFSample* client_sample = nullptr; IMFMediaBuffer* client_buffer = nullptr;
      call = MFCreateSample(&client_sample);
      if (SUCCEEDED(call)) call = MFCreateMemoryBuffer(info.cbSize, &client_buffer);
      if (SUCCEEDED(call)) call = client_sample->AddBuffer(client_buffer);
      release(client_buffer);
      if (FAILED(call)) { release(client_sample); return call; }
      output.pSample = client_sample;
      std::cout << label << " client_output_sample=true\n";
    }
    call = decoder->ProcessOutput(0, 1, &output, &status);
    if (call == MF_E_TRANSFORM_NEED_MORE_INPUT) return S_OK;
    if (call == MF_E_TRANSFORM_STREAM_CHANGE) {
      release(output.pEvents); release(output.pSample);
      std::cout << label << " stream_change\n";
      call = set_output_type(decoder, label);
      if (FAILED(call)) return call;
      continue;
    }
    if (FAILED(call)) {
      std::cout << label << " process_output_hr=" << hr(call) << "\n";
      return call;
    }
    ++result->frames;
    IMFMediaBuffer* buffer = nullptr; HRESULT buffer_hr = output.pSample ? output.pSample->GetBufferByIndex(0, &buffer) : E_FAIL;
    IMFDXGIBuffer* dxgi = nullptr; HRESULT dxgi_hr = SUCCEEDED(buffer_hr) ? buffer->QueryInterface(IID_PPV_ARGS(&dxgi)) : buffer_hr;
    ID3D11Texture2D* texture = nullptr; UINT subresource = 0;
    if (SUCCEEDED(dxgi_hr)) dxgi_hr = dxgi->GetResource(IID_PPV_ARGS(&texture));
    if (SUCCEEDED(dxgi_hr)) dxgi_hr = dxgi->GetSubresourceIndex(&subresource);
    if (SUCCEEDED(dxgi_hr)) {
      result->any_gpu = true;
      D3D11_TEXTURE2D_DESC description{}; texture->GetDesc(&description); result->subtype = GUID_NULL;
      std::cout << label << " frame=" << result->frames << " size=" << description.Width << "x" << description.Height
                << " format=" << format_name(description.Format) << " gpu_backed=true\n";
      if (collect_luma) { const HRESULT luma_hr = append_luma(texture, subresource, device, result); std::cout << label << " frame=" << result->frames << " luma_copy_hr=" << hr(luma_hr) << "\n"; if (FAILED(luma_hr)) call = luma_hr; }
    } else {
      result->all_gpu = false;
      std::cout << label << " frame=" << result->frames << " gpu_backed=false dxgi_buffer_hr=" << hr(dxgi_hr) << "\n";
    }
    release(texture); release(dxgi); release(buffer); release(output.pEvents); release(output.pSample);
    if (FAILED(call)) return call;
  }
}

HRESULT decode(const std::vector<std::vector<uint8_t>>& access_units, Device& device, uint32_t profile, const char* label, bool collect_luma, DecodeResult* result) {
  IMFTransform* decoder = nullptr;
  HRESULT call = CoCreateInstance(CLSID_CMSH264DecoderMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&decoder));
  std::cout << label << " cocreate_hr=" << hr(call) << "\n";
  if (SUCCEEDED(call)) call = configure(decoder, device, profile, label);
  if (SUCCEEDED(call)) report_current_types(decoder, label);
  if (SUCCEEDED(call)) call = decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  if (SUCCEEDED(call)) call = decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  for (size_t index = 0; SUCCEEDED(call) && index < access_units.size(); ++index) {
    IMFMediaBuffer* bytes = nullptr; IMFSample* sample = nullptr;
    call = MFCreateMemoryBuffer(static_cast<DWORD>(access_units[index].size()), &bytes);
    if (SUCCEEDED(call)) { BYTE* target = nullptr; DWORD capacity = 0; call = bytes->Lock(&target, &capacity, nullptr); if (SUCCEEDED(call)) { memcpy(target, access_units[index].data(), access_units[index].size()); bytes->Unlock(); call = bytes->SetCurrentLength(static_cast<DWORD>(access_units[index].size())); } }
    if (SUCCEEDED(call)) call = MFCreateSample(&sample);
    if (SUCCEEDED(call)) call = sample->AddBuffer(bytes);
    if (SUCCEEDED(call)) call = sample->SetSampleTime(static_cast<LONGLONG>(index) * 333333);
    if (SUCCEEDED(call)) call = sample->SetSampleDuration(333333);
    if (SUCCEEDED(call) && index == 0) call = sample->SetUINT32(MFSampleExtension_CleanPoint, TRUE);
    if (SUCCEEDED(call)) call = decoder->ProcessInput(0, sample, 0);
    std::cout << label << " input_au=" << (index + 1) << " bytes=" << access_units[index].size() << " process_input_hr=" << hr(call) << "\n";
    release(sample); release(bytes);
    if (SUCCEEDED(call)) call = drain_output(decoder, device, label, collect_luma, result);
  }
  if (SUCCEEDED(call)) { const HRESULT drain = decoder->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0); std::cout << label << " command_drain_hr=" << hr(drain) << "\n"; if (SUCCEEDED(drain)) call = drain_output(decoder, device, label, collect_luma, result); }
  decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
  IMFShutdown* shutdown = nullptr; if (SUCCEEDED(decoder->QueryInterface(IID_PPV_ARGS(&shutdown)))) { shutdown->Shutdown(); release(shutdown); }
  release(decoder);
  return call;
}

bool load_access_units(const std::filesystem::path& directory, const char* prefix, std::vector<std::vector<uint8_t>>* output) {
  for (int index = 1; index <= 3; ++index) { std::vector<uint8_t> bytes; const auto path = directory / (std::string(prefix) + "-" + std::to_string(index) + ".h264"); if (!read_file(path, &bytes)) { std::cerr << "cannot_read=" << path.string() << "\n"; return false; } output->push_back(std::move(bytes)); }
  return true;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  std::cout << std::unitbuf;
  std::cerr << std::unitbuf;
  if (argc != 4) { std::cerr << "usage: viewflow_windows_decode_sample <color-dir> <alpha-dir> <expected-alpha.gray>\n"; return 64; }
  const std::filesystem::path color_dir = argv[1], alpha_dir = argv[2], expected_path = argv[3];
  std::vector<std::vector<uint8_t>> color, alpha; std::vector<uint8_t> expected;
  if (!load_access_units(color_dir, "color", &color) || !load_access_units(alpha_dir, "alpha", &alpha) || !read_file(expected_path, &expected)) return 65;
  HRESULT call = CoInitializeEx(nullptr, COINIT_MULTITHREADED); if (FAILED(call)) { std::cerr << "coinitialize_hr=" << hr(call) << "\n"; return 2; }
  call = MFStartup(MF_VERSION); if (FAILED(call)) { std::cerr << "mfstartup_hr=" << hr(call) << "\n"; CoUninitialize(); return 2; }
  Device device; call = create_device(&device); std::cout << "create_device_manager_hr=" << hr(call) << "\n";
  DecodeResult color_result, alpha_result;
  if (SUCCEEDED(call)) { const HRESULT color_hr = decode(color, device, 100, "color", false, &color_result); std::cout << "color_result_hr=" << hr(color_hr) << " frames=" << color_result.frames << " gpu_status=" << (color_result.frames == 0 ? "not_observed" : color_result.all_gpu ? "all_gpu" : "non_gpu_output") << "\n"; }
  if (SUCCEEDED(call)) { const HRESULT alpha_hr = decode(alpha, device, 244, "alpha", true, &alpha_result); std::cout << "alpha_result_hr=" << hr(alpha_hr) << " frames=" << alpha_result.frames << " gpu_status=" << (alpha_result.frames == 0 ? "not_observed" : alpha_result.all_gpu ? "all_gpu" : "non_gpu_output") << "\n"; if (!alpha_result.luma.empty()) { const bool exact = alpha_result.luma == expected; std::cout << "alpha_byte_exact=" << (exact ? "true" : "false") << " decoded_luma_bytes=" << alpha_result.luma.size() << " expected_bytes=" << expected.size() << "\n"; } }
  MFShutdown(); CoUninitialize();
  return 0;
}
