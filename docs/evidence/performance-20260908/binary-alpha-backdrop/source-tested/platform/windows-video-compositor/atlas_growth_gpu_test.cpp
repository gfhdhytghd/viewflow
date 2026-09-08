// Hardware-only regression probe; owns its images and never opens a desktop window.
#include "video_compositor.h"
#include <mfapi.h>
#include <array>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>
using namespace viewflow::windows;
int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 64;
  if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 2;
  if (FAILED(MFStartup(MF_VERSION))) { CoUninitialize(); return 2; }
  const int result = [&]() -> int {
    GpuVideoCompositor compositor;
    HRESULT hr = GpuVideoCompositor::Create(&compositor, 0, 4);
    if (FAILED(hr)) { std::cerr << "create failed " << std::hex << hr << '\n'; return 3; }
    constexpr std::array<std::pair<uint32_t, uint32_t>, 3> sizes{{{1024,1024},{4096,4096},{8192,4096}}};
    size_t completed = 0;
    for (size_t i = 0; i < sizes.size(); ++i) {
      const auto [width, height] = sizes[i];
      std::ifstream file(std::filesystem::path(argv[1]) / (L"color-" + std::to_wstring(i+1) + L".av1"), std::ios::binary);
      std::vector<uint8_t> color((std::istreambuf_iterator<char>(file)), {});
      if (color.empty()) return 65;
      std::vector<uint8_t> alpha(size_t(width)*height, 0);
      std::vector<CompositedFrame> frames;
      hr = compositor.Submit(i+1, color, RawGray8Alpha{i+1,width,height,alpha}, &frames);
      if (FAILED(hr)) { auto g=compositor.decoder_geometry(); std::cerr << "geometry=" << g.negotiated_width << "x" << g.negotiated_height << " texture=" << g.texture_width << "x" << g.texture_height << " aperture=" << g.aperture_width << "x" << g.aperture_height << "\n"; std::cerr << "submit failed frame=" << i+1 << " hr=" << std::hex << hr << '\n'; return 4; }
      for (const auto& frame : frames) {
        if (frame.frame_identity != completed+1 || frame.width != sizes[completed].first || frame.height != sizes[completed].second) return 5;
        std::cout << "PASS frame=" << frame.frame_identity << " gpu_composite=" << frame.width << 'x' << frame.height << std::endl;
        ++completed;
      }
    }
    return completed == sizes.size() ? 0 : 6;
  }();
  MFShutdown(); CoUninitialize(); return result;
}
