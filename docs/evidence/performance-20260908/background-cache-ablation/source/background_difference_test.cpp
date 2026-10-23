#include "background_difference.h"
#include <chrono>
#include <cstdio>
#include <stdexcept>
#include <thread>
#include <vector>

void require(bool ok, const char *text) {
  if (!ok)
    throw std::runtime_error(text);
}
int main() {
  try {
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext> context;
    winrt::check_hresult(D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
        device.put(), nullptr, context.put()));
    winrt::com_ptr<ID3D11Query> query;
    D3D11_QUERY_DESC q{D3D11_QUERY_EVENT, 0};
    winrt::check_hresult(device->CreateQuery(&q, query.put()));
    unsigned cases = 0;
    for (UINT tolerance : {0u, 1u}) {
    for (auto size :
         std::array<std::array<UINT, 2>, 2>{{{129, 65}, {3839, 2399}}}) {
      const auto [w, h] = size;
      BackgroundDifference diff;
      diff.Initialize(device.get(), w, h, tolerance);
      D3D11_TEXTURE2D_DESC td{};
      td.Width = w;
      td.Height = h;
      td.MipLevels = td.ArraySize = td.SampleDesc.Count = 1;
      td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
      winrt::com_ptr<ID3D11Texture2D> current;
      winrt::check_hresult(
          device->CreateTexture2D(&td, nullptr, current.put()));
      std::vector<unsigned char> bytes(size_t(w) * h * 4, 100);
      for (size_t i = 3; i < bytes.size(); i += 4)
        bytes[i] = 255;
      auto upload = [&] {
        context->UpdateSubresource(current.get(), 0, nullptr, bytes.data(),
                                   w * 4, 0);
      };
      upload();
      diff.Remember(current.get());
      auto check = [&](bool expected, const char *name) {
        diff.Begin(current.get());
        context->End(query.get());
        context->Flush();
        const auto until =
            std::chrono::steady_clock::now() + std::chrono::seconds(5);
        for (;;) {
          require(std::chrono::steady_clock::now() < until,
                  "GPU oracle operation timeout");
          BOOL done = FALSE;
          const auto hr = context->GetData(query.get(), &done, sizeof(done),
                                           D3D11_ASYNC_GETDATA_DONOTFLUSH);
          winrt::check_hresult(hr);
          if (hr == S_OK && done) {
            if (auto result = diff.TryResult()) {
              if (*result != expected) {
                std::printf("FAIL %s size=%u,%u actual=%d\n", name, w, h,
                            int(*result));
                require(false, "difference mismatch");
              }
              ++cases;
              break;
            }
          }
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
      };
      check(false, "identical");
      for (size_t i = 0; i < bytes.size(); ++i)
        if (i % 4 != 3)
          bytes[i] = 101;
      upload();
      check(tolerance == 0, "one SDR code change");
      bytes[bytes.size() - 4] = 102;
      upload();
      check(true, "last pixel cumulative change");
      diff.Remember(current.get());
      check(false, "new reference");
      bytes[0] = 99;
      upload();
      check(true, "first pixel negative change");
      bytes[0] = 101;
      bytes[bytes.size() / 8 * 4 + 3] = 254;
      upload();
      check(true, "alpha remains exact");
      bytes[bytes.size() / 8 * 4 + 3] = 255;
      upload();
      check(false, "restore latest reference");
      bytes[(size_t(16) * w + 16) * 4 + 1] = 103;
      upload();
      check(true, "workgroup boundary");
      std::printf("PASS background difference size=%u,%u cases=%u\n", w, h,
                  cases);
    }
    }
    std::printf("PASS full pixel comparison cases=%u "
                "cpu_readback_bytes_per_check=4 input_injected=0\n",
                cases);
    return 0;
  } catch (winrt::hresult_error const &e) {
    std::fprintf(stderr, "HRESULT=%08x %ls\n", unsigned(e.code()),
                 e.message().c_str());
    return 1;
  } catch (std::exception const &e) {
    std::fprintf(stderr, "error=%s\n", e.what());
    return 1;
  }
}
