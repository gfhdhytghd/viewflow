#pragma once
#include "background_region.h"
#include "hyprland_blur.h"
// One immutable geometry generation. Construct and destroy on the cache worker.
class BackgroundBuffer {
  using Surface = winrt::Windows::UI::Composition::CompositionDrawingSurface;
  enum Status { Free, Writing, Ready, Displayed, Retired };
  struct Slot {
    Surface surface{nullptr};
    Status status = Free;
  };
  struct State {
    std::mutex mutex;
    std::array<Slot, 3> slots;
    int ready = -1, displayed = -1;
    std::atomic<uint64_t> captures{}, published{}, taken{}, busy{}, ticks{},
        gpu_pending{};
    std::atomic<int64_t> first_published_us{}, last_published_us{};
    std::atomic<long> error{};
  };
  std::shared_ptr<State> state_ = std::make_shared<State>();
  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::com_ptr<ID2D1Device> d2d_;
  winrt::Windows::UI::Composition::CompositionGraphicsDevice graphics_{nullptr};
  winrt::Windows::UI::Composition::ContainerVisual parent_{nullptr};
  winrt::Windows::UI::Composition::SpriteVisual source_{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool pool_{nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession capture_{nullptr};
  winrt::com_ptr<ID3D11Query> query_;
  std::jthread worker_;
  std::atomic<bool> started_{};
  std::atomic<uint64_t> offset_bits_{};
  HyprlandBlur blur_;
  UINT width_, height_, hz_;
  winrt::Windows::Foundation::Numerics::float2 offset_{};
  viewflow::background::Plan region_;
  viewflow::background::Rect placed_window_{}, placed_anchor_{};

public:
  static constexpr float halo = 128;
  struct Publication {
    Surface surface{nullptr};
    int retired = -1;
  };
  BackgroundBuffer(Compositor const &c, ID3D11Device *foreground,
                   viewflow::background::Plan region,
                   viewflow::background::Rect monitor, UINT hz = 30)
      : width_(UINT(region.bounds.width())),
        height_(UINT(region.bounds.height())), hz_(hz), region_(region) {
    using namespace winrt;
    using namespace winrt::Windows::Graphics;
    if (region.bounds.empty() || !region.fits_texture)
      throw hresult_error(E_INVALIDARG);
    const float mw = float(monitor.width()), mh = float(monitor.height());
    blur_.settings.noise_origin = {float(region.bounds.left - monitor.left) /
                                       mw,
                                   float(region.bounds.top - monitor.top) / mh};
    blur_.settings.noise_scale = {float(width_) / mw, float(height_) / mh};
    com_ptr<IDXGIDevice> fgdxgi;
    check_hresult(foreground->QueryInterface(fgdxgi.put()));
    com_ptr<IDXGIAdapter> adapter;
    check_hresult(fgdxgi->GetAdapter(adapter.put()));
    check_hresult(D3D11CreateDevice(adapter.get(), D3D_DRIVER_TYPE_UNKNOWN,
                                    nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                    nullptr, 0, D3D11_SDK_VERSION,
                                    device_.put(), nullptr, context_.put()));
    auto dxgi = device_.as<IDXGIDevice>();
    check_hresult(D2D1CreateDevice(dxgi.get(), nullptr, d2d_.put()));
    auto interop = c.as<ABI::Windows::UI::Composition::ICompositorInterop>();
    check_hresult(interop->CreateGraphicsDevice(
        d2d_.get(),
        reinterpret_cast<
            ABI::Windows::UI::Composition::ICompositionGraphicsDevice **>(
            put_abi(graphics_))));
    for (auto &slot : state_->slots)
      slot.surface = graphics_.CreateDrawingSurface(
          {float(width_), float(height_)},
          winrt::Windows::Graphics::DirectX::DirectXPixelFormat::
              B8G8R8A8UIntNormalized,
          winrt::Windows::Graphics::DirectX::DirectXAlphaMode::Premultiplied);
    parent_ = c.CreateContainerVisual();
    // The UI supplies a current opaque anchor before attaching this parent.
    parent_.Clip(c.CreateInsetClip(0, 0, 0, 0));
    source_ = c.CreateSpriteVisual();
    source_.Size({float(width_), float(height_)});
    SparsePrototypeBlur effect;
    effect.sigma = 0;
    effect.Source(CompositionEffectSourceParameter(L"background"));
    auto brush = c.CreateEffectFactory(effect).CreateBrush();
    brush.SetSourceParameter(L"background", c.CreateHostBackdropBrush());
    source_.Brush(brush);
    parent_.Children().InsertAtTop(source_);
    winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice winrt_device{
        nullptr};
    check_hresult(CreateDirect3D11DeviceFromDXGIDevice(
        dxgi.get(),
        reinterpret_cast<::IInspectable **>(put_abi(winrt_device))));
    blur_.Initialize(device_.get(), width_, height_);
    auto item = Capture::GraphicsCaptureItem::CreateFromVisual(source_);
    pool_ = Capture::Direct3D11CaptureFramePool::CreateFreeThreaded(
        winrt_device,
        winrt::Windows::Graphics::DirectX::DirectXPixelFormat::
            B8G8R8A8UIntNormalized,
        3, {int(width_), int(height_)});
    capture_ = pool_.CreateCaptureSession(item);
    capture_.IsCursorCaptureEnabled(false);
    capture_.MinUpdateInterval(winrt::Windows::Foundation::TimeSpan{0});
    D3D11_QUERY_DESC q{D3D11_QUERY_EVENT, 0};
    check_hresult(device_->CreateQuery(&q, query_.put()));
    RunWorker();
  }
  ~BackgroundBuffer() {
    if (worker_.joinable()) {
      worker_.request_stop();
      worker_.join();
    }
    try {
      if (capture_)
        capture_.Close();
      if (pool_)
        pool_.Close();
    } catch (...) {
    }
  }
  auto Parent() const { return parent_; }
#ifdef VIEWFLOW_BACKGROUND_CACHE_TESTING
  auto SourceForTest() const { return source_; }
#endif
  auto Region() const { return region_; }
  void Place(Compositor const &c, viewflow::background::Rect window,
             viewflow::background::Rect anchor) {
    if (window == placed_window_ && anchor == placed_anchor_)
      return;
    const auto [x, y] =
        viewflow::background::brush_offset(region_.bounds, window);
    // CreateFromVisual(child) does not use a parent's translation as the
    // capture origin. Let the worker update the captured visual itself.
    const std::array<float, 2> offset{float(x), float(y)};
    uint64_t bits{};
    std::memcpy(&bits, offset.data(), sizeof(bits));
    offset_bits_ = bits;
#ifdef VIEWFLOW_BACKGROUND_CACHE_HELPER_PROBE
    offset_bits_ = 0;
#endif
    parent_.Size({float(window.width()), float(window.height())});
    parent_.Clip(c.CreateInsetClip(float(anchor.left), float(anchor.top),
                                   float(window.width() - anchor.right),
                                   float(window.height() - anchor.bottom)));
#ifdef VIEWFLOW_BACKGROUND_CACHE_TESTING
    parent_.Clip(nullptr);
#endif
#ifdef VIEWFLOW_BACKGROUND_CACHE_HELPER_PROBE
    parent_.Size({float(width_), float(height_)});
#endif
    placed_window_ = window;
    placed_anchor_ = anchor;
  }
  void Hide() { parent_.Opacity(0); }
  void Show() {
#ifdef VIEWFLOW_BACKGROUND_CACHE_TESTING
    parent_.Opacity(0.000001f);
#else
    parent_.Opacity(1);
#endif
  }
  bool Failed() const { return state_->error.load() != 0; }

  void Start() { started_ = true; }
  void RunWorker() {
    worker_ = std::jthread([this](std::stop_token stop) {
      winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame pending_frame{
          nullptr};
      try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        while (!started_ && !stop.stop_requested())
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (stop.stop_requested())
          return;
        uint64_t last_offset = offset_bits_.load();
        std::memcpy(&offset_, &last_offset, sizeof(last_offset));
        source_.Offset({offset_.x, offset_.y, 0});
        capture_.StartCapture();
        int pending = -1;
        auto next = std::chrono::steady_clock::now();
        while (!stop.stop_requested()) {
          const auto now = std::chrono::steady_clock::now();
          const uint64_t geometry_bits = offset_bits_.load();
          if (geometry_bits != last_offset) {
            // Discard queued geometry-obsolete captures; keep in-flight GPU
            // work alive until its completion query releases the frame.
            for (unsigned i = 0; i < 3; ++i) {
              auto stale = pool_.TryGetNextFrame();
              if (!stale)
                break;
              stale.Close();
            }
            std::memcpy(&offset_, &geometry_bits, sizeof(geometry_bits));
            last_offset = geometry_bits;
            source_.Offset({offset_.x + float(state_->ticks.load() % 2) * 0.01f,
                            offset_.y, 0});
          }
          if (now >= next) {
            const auto tick = ++state_->ticks;
            source_.Offset({offset_.x + float(tick % 2) * 0.01f, offset_.y, 0});
            next += std::chrono::nanoseconds(1000000000 / hz_);
            if (now >= next + std::chrono::nanoseconds(1000000000 / hz_))
              next = now + std::chrono::nanoseconds(1000000000 / hz_);
          }
          if (pending >= 0) {
            BOOL done = FALSE;
            auto hr = context_->GetData(query_.get(), &done, sizeof(done),
                                        D3D11_ASYNC_GETDATA_DONOTFLUSH);
            winrt::check_hresult(hr);
            if (hr == S_OK && done) {
              pending_frame.Close();
              pending_frame = nullptr;
              std::lock_guard lock(state_->mutex);
              if (state_->ready >= 0)
                state_->slots[state_->ready].status = Free;
              state_->slots[pending].status = Ready;
              state_->ready = pending;
              const auto us =
                  std::chrono::duration_cast<std::chrono::microseconds>(
                      now.time_since_epoch())
                      .count();
              if (!state_->published.load())
                state_->first_published_us = us;
              state_->last_published_us = us;
              ++state_->published;
              pending = -1;
            } else {
              ++state_->gpu_pending;
              std::this_thread::sleep_for(std::chrono::milliseconds(1));
              continue;
            }
          }
          auto frame = pool_.TryGetNextFrame();
          if (!frame) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
          }
          ++state_->captures;
          int index = -1;
          {
            std::lock_guard lock(state_->mutex);
            for (int i = 0; i < 3; ++i)
              if (state_->slots[i].status == Free) {
                state_->slots[i].status = Writing;
                index = i;
                break;
              }
          }
          if (index < 0) {
            ++state_->busy;
            frame.Close();
            continue;
          }
          pending_frame = frame;
          auto access = frame.Surface()
                            .as<::Windows::Graphics::DirectX::Direct3D11::
                                    IDirect3DDxgiInterfaceAccess>();
          winrt::com_ptr<ID3D11Texture2D> texture;
          winrt::check_hresult(access->GetInterface(
              winrt::guid_of<ID3D11Texture2D>(), texture.put_void()));
          auto drawing =
              state_->slots[index]
                  .surface.as<ABI::Windows::UI::Composition::
                                  ICompositionDrawingSurfaceInterop>();
          winrt::com_ptr<ID3D11Texture2D> destination;
          POINT offset{};
          winrt::check_hresult(
              drawing->BeginDraw(nullptr, __uuidof(ID3D11Texture2D),
                                 destination.put_void(), &offset));
          D3D11_TEXTURE2D_DESC td{}, dd{};
          texture->GetDesc(&td);
          destination->GetDesc(&dd);
          if (td.Width < width_ || td.Height < height_ || offset.x < 0 ||
              offset.y < 0 || uint64_t(offset.x) + width_ > dd.Width ||
              uint64_t(offset.y) + height_ > dd.Height) {
            drawing->EndDraw();
            throw winrt::hresult_error(E_FAIL,
                                       L"background surface size mismatch");
          }
          winrt::com_ptr<ID3D11ShaderResourceView> srv;
          winrt::com_ptr<ID3D11RenderTargetView> rtv;
          try {
            winrt::check_hresult(device_->CreateShaderResourceView(
                texture.get(), nullptr, srv.put()));
            winrt::check_hresult(device_->CreateRenderTargetView(
                destination.get(), nullptr, rtv.put()));
            blur_.Draw(srv.get(), rtv.get(), offset);
          } catch (...) {
            drawing->EndDraw();
            throw;
          }
          winrt::check_hresult(drawing->EndDraw());
          context_->End(query_.get());
          context_->Flush();
          pending = index;
        }
        // Stop capture before releasing a frame whose GPU work may still be
        // pending.
        capture_.Close();
        pool_.Close();
        context_->Flush();
      } catch (winrt::hresult_error const &e) {
        state_->error = e.code().value;
      } catch (...) {
        state_->error = E_FAIL;
      }
      try {
        capture_.Close();
        pool_.Close();
        if (pending_frame)
          pending_frame.Close();
      } catch (...) {
      }
    });
  }
  std::optional<Publication> Take() {
    std::unique_lock lock(state_->mutex, std::try_to_lock);
    if (!lock || state_->ready < 0)
      return {};
    const auto index = state_->ready, old = state_->displayed;
    state_->ready = -1;
    state_->displayed = index;
    state_->slots[index].status = Displayed;
    if (old >= 0)
      state_->slots[old].status = Retired;
    ++state_->taken;
    return Publication{state_->slots[index].surface, old};
  }
  void RetireAfterCommit(Compositor const &c, int index) {
    if (index < 0)
      return;
    auto state = state_;
    c.RequestCommitAsync().Completed([state, index](auto const &, auto status) {
      if (status != winrt::Windows::Foundation::AsyncStatus::Completed) {
        state->error = E_FAIL;
        return;
      }
      std::lock_guard lock(state->mutex);
      if (state->slots[index].status == Retired)
        state->slots[index].status = Free;
    });
  }
  void Report(FILE *log) {
    const auto first = state_->first_published_us.load(),
               last = state_->last_published_us.load(),
               count = int64_t(state_->published.load());
    const double rate =
        last > first ? double(count - 1) * 1000000.0 / double(last - first) : 0;
    std::fprintf(
        log,
        "background-cache hz=%u width=%u height=%u kernel=%lld motion_x=%lld "
        "motion_y=%lld captures=%llu published=%llu taken=%llu busy=%llu "
        "ticks=%llu gpu_pending_polls=%llu error=%08lx publication_hz=%.3f "
        "separate_device=1 blur=hyprland-0.56.2 radius=5 passes=4 "
        "contrast=0.8916 brightness=1 noise=0.0117 vibrancy=0.1696\n",
        hz_, width_, height_, region_.kernel, region_.motion_x,
        region_.motion_y, state_->captures.load(), state_->published.load(),
        state_->taken.load(), state_->busy.load(), state_->ticks.load(),
        state_->gpu_pending.load(), state_->error.load(), rate);
  }
};
