// Production upload path with a deliberately delayed compositor commit.
// No window, desktop capture, focus change, or input is needed.
#define wmain viewflow_unused_preview_entry
#include "main.cpp"
#undef wmain
#include <cassert>

winrt::Windows::Foundation::IAsyncAction pending_commit(HANDLE ready) {
  co_await winrt::resume_on_signal(ready);
}
winrt::Windows::Foundation::IAsyncAction completed_commit() { co_return; }

int wmain() try {
  init_apartment(apartment_type::single_threaded);
  DispatcherQueueOptions options{sizeof(options), DQTYPE_THREAD_CURRENT, DQTAT_COM_STA};
  com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;
  check_hresult(CreateDispatcherQueueController(options, queue.put()));
  Compositor compositor;
  auto owner = foreground(compositor, 64, 64);
  std::vector<uint32_t> pixels(64 * 64, 0xff123456);
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = desc.Height = 64; desc.MipLevels = desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM; desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  D3D11_SUBRESOURCE_DATA data{pixels.data(), 64 * 4, 0};
  viewflow::windows::CompositedFrame frame;
  frame.frame_identity = 1; frame.width = frame.height = 64;
  check_hresult(owner.d3d->CreateTexture2D(&desc, &data, frame.premultiplied_bgra.GetAddressOf()));
  auto original = stage_gpu_surface(owner, compositor, frame);
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  assert(ready);
  auto pending = pending_commit(ready);
  assert(pending.Status() == winrt::Windows::Foundation::AsyncStatus::Started);
  owner.spare_surface = original.surface; owner.spare_brush = original.brush;
  owner.spare_commit = pending;
  auto during = stage_gpu_surface(owner, compositor, frame);
  assert(during.surface != original.surface);
  // A successfully committed retirement becomes reusable, without discarding
  // the pool optimization or copying a full image per window.
  owner.spare_surface = original.surface; owner.spare_brush = original.brush;
  owner.spare_commit = completed_commit();
  auto after = stage_gpu_surface(owner, compositor, frame);
  assert(after.surface == original.surface);
  // A missing fence is not proof of retirement either.
  owner.spare_surface = original.surface; owner.spare_brush = original.brush;
  owner.spare_commit = nullptr;
  auto unfenced = stage_gpu_surface(owner, compositor, frame);
  assert(unfenced.surface != original.surface);
  SetEvent(ready);
  for (unsigned i = 0; i < 100 && pending.Status() == winrt::Windows::Foundation::AsyncStatus::Started; ++i) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
    Sleep(1);
  }
  assert(pending.Status() == winrt::Windows::Foundation::AsyncStatus::Completed);
  pending.GetResults();
  CloseHandle(ready);
  std::puts("PASS pending/unfenced surfaces stay immutable; completed retirement permits reuse");
}
 catch (winrt::hresult_error const& error) {
  std::fprintf(stderr, "FAIL stage=%s HRESULT=%08x\n", stage, unsigned(error.code())); return 1;
} catch (std::exception const& error) {
  std::fprintf(stderr, "FAIL stage=%s %s\n", stage, error.what()); return 1;
}
