#include "video_compositor.h"
#include "direct_decoder_probe.h"
#include <mfapi.h>
#include <windows.h>
#include <cstdio>
#include <cwchar>
#include <thread>

// Diagnostic only: bound even a driver call or destructor that never returns.
// The watchdog terminates only this fresh probe process, not another process.
int wmain(int argc, wchar_t** argv) {
  if (argc != 2 || (wcscmp(argv[1], L"sta") && wcscmp(argv[1], L"mta") &&
                    wcscmp(argv[1], L"worker-mta") && wcscmp(argv[1], L"direct-d3d") &&
                    wcscmp(argv[1], L"direct-d3d-1080") && wcscmp(argv[1], L"mta-two-workers")))
    return 64;
  const bool sta = wcscmp(argv[1], L"sta") == 0;
  const bool worker = wcscmp(argv[1], L"worker-mta") == 0;
  HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!done) return 2;
  std::thread watchdog([done] {
    if (WaitForSingleObject(done, 10000) != WAIT_OBJECT_0) {
      std::fprintf(stderr, "init-probe watchdog timeout\n");
      std::fflush(stderr);
      TerminateProcess(GetCurrentProcess(), 124);
    }
  });
  SetEnvironmentVariableW(L"VIEWFLOW_GPU_INIT_TIMINGS", L"1");
  std::printf("apartment=%s pid=%lu\n", sta ? "sta" : "mta", GetCurrentProcessId());
  std::fflush(stdout);
  int result = 2;
  auto initialize = [&] {
  if (wcscmp(argv[1], L"direct-d3d-1080") == 0) {
    result = SUCCEEDED(ProbeDirectDecoder(1920, 1080)) ? 0 : 3;
    return;
  }
  if (wcscmp(argv[1], L"direct-d3d") == 0) {
    result = SUCCEEDED(ProbeDirectDecoder()) ? 0 : 3;
    return;
  }
  std::printf("decoder_thread=%lu worker=%d\n", GetCurrentThreadId(), worker);
  std::fflush(stdout);
  HRESULT hr = CoInitializeEx(nullptr, sta ? COINIT_APARTMENTTHREADED : COINIT_MULTITHREADED);
  if (SUCCEEDED(hr)) {
    hr = MFStartup(MF_VERSION);
    if (SUCCEEDED(hr)) {
      {
        viewflow::windows::GpuVideoCompositor compositor;
        hr = viewflow::windows::GpuVideoCompositor::Create(&compositor,
            wcscmp(argv[1], L"mta-two-workers") == 0 ? 2 : 0);
        std::printf("create_hresult=0x%08lx\n", static_cast<unsigned long>(hr));
        std::fflush(stdout);
        result = SUCCEEDED(hr) ? 0 : 3;
      }
      MFShutdown();
    }
    CoUninitialize();
  }
  };
  if (worker) {
    std::thread decoder(initialize);
    decoder.join();
  } else {
    initialize();
  }
  SetEvent(done);
  watchdog.join();
  CloseHandle(done);
  return result;
}
