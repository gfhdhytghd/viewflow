#pragma once
#include "background_buffer.h"

// UI methods only change visual descriptors and use try_lock for mailboxes.
// Allocation, shader compilation, GPU work and generation destruction run off
// the foreground thread. Each proxy retains its own HostBackdrop Z-order cut.
class NativeBackgroundCache {
  using Rect = viewflow::background::Rect;
  struct Request {
    viewflow::background::Plan plan;
    Rect monitor;
    uint64_t sequence{};
  };
  struct Shared {
    std::mutex mutex;
    std::optional<Request> request;
    std::shared_ptr<BackgroundBuffer> prepared;
    uint64_t prepared_sequence{};
    std::atomic<bool> stop{};
    std::atomic<uint64_t> builds{}, failures{};
  };
  Compositor compositor_{nullptr};
  UINT hz_ = 30;
  std::shared_ptr<Shared> shared_ = std::make_shared<Shared>();
  std::shared_ptr<BackgroundBuffer> active_, warming_;
  CompositionDrawingSurface surface_{nullptr};
  Rect last_window_{}, last_desktop_{};
  viewflow::background::Plan requested_{};
  uint64_t sequence_{};
  uint64_t seen_failures_{};
  uint64_t updates_{}, cached_updates_{}, publications_{}, local_errors_{};
  std::chrono::steady_clock::time_point last_time_{}, retry_after_{},
      last_motion_{};

  static Rect Window(HWND hwnd) {
    RECT r{};
    POINT p{};
    if (!GetClientRect(hwnd, &r) || !ClientToScreen(hwnd, &p))
      return {};
    return {p.x, p.y, int64_t(p.x) + r.right, int64_t(p.y) + r.bottom};
  }
  static Rect Display(HWND hwnd) {
    MONITORINFO monitor{sizeof(monitor)};
    if (!GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                         &monitor))
      return {};
    return {monitor.rcMonitor.left, monitor.rcMonitor.top,
            monitor.rcMonitor.right, monitor.rcMonitor.bottom};
  }
  void Detach(std::shared_ptr<BackgroundBuffer> &generation) {
    if (!generation)
      return;
    generation->Hide();
    // The worker owns the final engine reference. Existing surface brushes
    // retain their immutable displayed surface after this generation closes.
    generation.reset();
  }
  static void Restore(Foreground &fg) {
    if (fg.shared_sparse)
      for (auto &[key, node] : fg.shared_sparse->nodes)
        if (node.background) {
          if (!node.cached_parts.empty())
            node.background.Children().RemoveAll();
          node.background.Brush(node.masked);
          node.background_cached = false;
        }
  }
  bool Bind(Foreground &fg, Rect window, Rect desktop) {
    if (!active_ || !surface_ || !fg.shared_sparse) {
      Restore(fg);
      return false;
    }
    auto const region = active_->Region();
    if (active_->DisplayBounds() != desktop ||
        !viewflow::background::usable(region.bounds, desktop, region.kernel)
             .contains(viewflow::background::intersect(window, desktop))) {
      Restore(fg);
      return false;
    }
    auto &scene = *fg.shared_sparse;
    if (!scene.cached_factory) {
      auto transform = make_self<SparseMaskTransform>();
      transform->source = CompositionEffectSourceParameter(L"atlas");
      auto composite = make_self<SparseBackdropComposite>();
      composite->sources[0] = transform.as<IGraphicsEffectSource>();
      composite->sources[1] = CompositionEffectSourceParameter(L"backdrop");
      scene.cached_factory = compositor_.CreateEffectFactory(
          composite.as<IGraphicsEffect>(),
          {L"SparseMaskTransform.TransformMatrix"});
    }
    const auto scale = fg.sparse_root.Scale();
    if (scale.x <= 0 || scale.y <= 0) {
      Restore(fg);
      return false;
    }
    for (auto &[key, node] : scene.nodes) {
      if (!node.background)
        continue;
      if (!node.cached_masked) {
        node.cached_backdrop = compositor_.CreateSurfaceBrush();
        node.cached_backdrop.Stretch(CompositionStretch::None);
        node.cached_backdrop.HorizontalAlignmentRatio(0);
        node.cached_backdrop.VerticalAlignmentRatio(0);
        node.cached_masked = scene.cached_factory.CreateBrush();
        node.cached_masked.SetSourceParameter(L"atlas", scene.brush);
        node.cached_masked.SetSourceParameter(L"backdrop",
                                              node.cached_backdrop);
        node.cached_masked.Properties().InsertMatrix3x2(
            L"SparseMaskTransform.TransformMatrix",
            {1, 0, 0, 1, -float(node.atlas_x), -float(node.atlas_y)});
      }
      const auto [x, y, w, h, opaque] = key;
      node.cached_backdrop.Surface(surface_);
      node.cached_backdrop.Scale({1 / scale.x, 1 / scale.y});
      node.cached_backdrop.Offset(
          {float(region.bounds.left - window.left) / scale.x - float(x),
           float(region.bounds.top - window.top) / scale.y - float(y)});
      const auto regions = viewflow::background::display_partition(
          float(w), float(h),
          {float(desktop.left - window.left) / scale.x - float(x),
           float(desktop.top - window.top) / scale.y - float(y),
           float(desktop.right - window.left) / scale.x - float(x),
           float(desktop.bottom - window.top) / scale.y - float(y)});
      const auto [left, top, right, bottom] = regions[0];
      if (right <= left || bottom <= top) {
        if (!node.cached_parts.empty())
          node.background.Children().RemoveAll();
        node.background.Brush(node.masked);
        node.background_cached = false;
      } else if (left == 0 && top == 0 && right == float(w) &&
                 bottom == float(h)) {
        if (!node.cached_parts.empty())
          node.background.Children().RemoveAll();
        node.background.Brush(node.cached_masked);
        node.background_cached = true;
      } else {
        // A straddling window uses this monitor's cache only inside its display
        // bounds. Disjoint outside strips retain the ordinary live backdrop.
        if (node.cached_parts.empty()) {
          std::vector<SpriteVisual> parts;
          for (int i = 0; i < 5; ++i) {
            auto part = compositor_.CreateSpriteVisual();
            part.Size({float(w), float(h)});
            part.Clip(compositor_.CreateInsetClip());
            parts.push_back(part);
          }
          node.cached_parts = std::move(parts);
        }
        if (node.background.Children().Count() == 0)
          for (auto const &part : node.cached_parts)
            node.background.Children().InsertAtTop(part);
        for (size_t i = 0; i < regions.size(); ++i) {
          auto const &r = regions[i];
          auto const &part = node.cached_parts[i];
          const auto clip = part.Clip().as<InsetClip>();
          clip.LeftInset(r[0]);
          clip.TopInset(r[1]);
          clip.RightInset(float(w) - r[2]);
          clip.BottomInset(float(h) - r[3]);
          part.IsVisible(r[2] > r[0] && r[3] > r[1]);
          part.Brush(i == 0 ? node.cached_masked : node.masked);
        }
        node.background.Brush(nullptr);
        node.background_cached = true;
      }
    }
    return true;
  }

public:
  static bool Enabled() {
    static const bool enabled = [] {
      wchar_t text[2]{};
      return GetEnvironmentVariableW(L"VIEWFLOW_ATLAS_BACKGROUND_CACHE", text,
                                     2) == 1 &&
             text[0] == L'1';
    }();
    return enabled;
  }
  NativeBackgroundCache(Compositor c, ID3D11Device *device, HWND proxy)
      : compositor_(c) {
    winrt::com_ptr<ID3D11Device> foreground;
    foreground.copy_from(device);
    wchar_t rate[3]{};
    if (GetEnvironmentVariableW(L"VIEWFLOW_ATLAS_BACKGROUND_CACHE_HZ", rate,
                                3) == 2 &&
        rate[0] == L'1' && rate[1] == L'5')
      hz_ = 15;
    std::thread([state = shared_, c, foreground, proxy, hz = hz_] {
      try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        // The worker holds the final reference: releasing a generation on the
        // UI never joins its capture thread or frees its GPU textures.
        std::vector<std::shared_ptr<BackgroundBuffer>> generations;
        while (!state->stop) {
          std::optional<Request> request;
          {
            std::lock_guard lock(state->mutex);
            request = std::exchange(state->request, {});
          }
          if (request) {
            try {
              auto generation = std::make_shared<BackgroundBuffer>(
                  c, foreground.get(), request->plan, request->monitor, proxy,
                  hz);
              generations.push_back(generation);
              ++state->builds;
              std::lock_guard lock(state->mutex);
              state->prepared = std::move(generation);
              state->prepared_sequence = request->sequence;
            } catch (...) {
              ++state->failures;
            }
          }
          MSG message{};
          while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
          }
          for (auto const &generation : generations)
            generation->PumpHost();
          std::erase_if(generations,
                        [](auto const &g) { return g.use_count() == 1; });
          std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        {
          std::lock_guard lock(state->mutex);
          state->prepared.reset();
        }
        generations.clear();
      } catch (...) {
        ++state->failures;
      }
    }).detach();
  }
  ~NativeBackgroundCache() {
    // Shutdown is local to this cache and never changes stream availability.
    try {
      Detach(warming_);
      Detach(active_);
    } catch (...) {
    }
    warming_.reset();
    active_.reset();
    shared_->stop = true;
  }
  void Update(HWND hwnd, Foreground &fg) noexcept {
    std::vector<std::pair<std::shared_ptr<BackgroundBuffer>, int>> retired;
    try {
      ++updates_;
      const auto window = Window(hwnd), desktop = Display(hwnd);
      if (window.empty() || desktop.empty() || !fg.shared_sparse ||
          std::none_of(fg.shared_sparse->nodes.begin(),
                       fg.shared_sparse->nodes.end(),
                       [](auto const &entry) {
                         return bool(entry.second.background);
                       }) ||
          !IsWindowVisible(hwnd) || IsIconic(hwnd)) {
        if (active_)
          active_->Hide();
        if (warming_)
          warming_->Hide();
        Restore(fg);
        return;
      }
      const auto now = std::chrono::steady_clock::now();
      const auto failures = shared_->failures.load();
      if (failures != seen_failures_) {
        seen_failures_ = failures;
        requested_ = {};
        retry_after_ = now + std::chrono::seconds(1);
      }
      double vx = 0, vy = 0;
      if (!last_window_.empty()) {
        const double dt =
            std::chrono::duration<double>(now - last_time_).count();
        if (dt > 0) {
          vx = (window.left - last_window_.left) / dt;
          vy = (window.top - last_window_.top) / dt;
        }
      }
      if (window != last_window_)
        last_motion_ = now;
      last_window_ = window;
      last_time_ = now;
      // Mailbox reads never wait for a constructor or a GPU operation.
      std::shared_ptr<BackgroundBuffer> prepared;
      uint64_t prepared_sequence{};
      {
        std::unique_lock lock(shared_->mutex, std::try_to_lock);
        if (lock && shared_->prepared) {
          prepared = std::move(shared_->prepared);
          prepared_sequence = shared_->prepared_sequence;
        }
      }
      if (prepared && prepared_sequence == sequence_) {
        Detach(warming_);
        warming_ = std::move(prepared);
        warming_->Start();
      }
      if (warming_) {
        if (active_)
          active_->Hide();
        warming_->Show();
      } else if (active_)
        active_->Show();
      if (warming_ && warming_->Failed()) {
        Detach(warming_);
        requested_ = {};
        retry_after_ = now + std::chrono::seconds(1);
      }
      if (active_ && active_->Failed()) {
        Detach(active_);
        surface_ = nullptr;
        requested_ = {};
        retry_after_ = now + std::chrono::seconds(1);
      }
      if (warming_)
        if (auto publication = warming_->Take()) {
          ++publications_;
          Detach(active_);
          active_ = std::move(warming_);
          surface_ = publication->surface;
          retired.emplace_back(active_, publication->retired);
        }
      if (active_)
        if (auto publication = active_->Take()) {
          ++publications_;
          surface_ = publication->surface;
          retired.emplace_back(active_, publication->retired);
        }
      const auto kernel = viewflow::background::hyprland_support(5, 4);
      std::optional<viewflow::background::Plan> idle_plan;
      // Startup placement or a fast drag can temporarily need a large reserve.
      // Once stationary, stop recomputing that unused region on every tick.
      if (now - last_motion_ >= std::chrono::milliseconds(250) &&
          (requested_.motion_x > 128 || requested_.motion_y > 128)) {
        auto smaller =
            viewflow::background::plan(window, desktop, kernel, 0, 0, hz_);
        if (smaller.bounds != requested_.bounds)
          idle_plan = smaller;
      }
      if (now >= retry_after_ &&
          (idle_plan || requested_.bounds.empty() || desktop != last_desktop_ ||
           viewflow::background::needs_urgent_refresh(requested_.bounds, window,
                                                      desktop, kernel))) {
        auto plan = idle_plan.value_or(
            viewflow::background::plan(window, desktop, kernel, vx, vy, hz_));
        if (plan.fits_texture && !plan.bounds.empty()) {
          std::unique_lock lock(shared_->mutex, std::try_to_lock);
          if (lock) {
            shared_->request = Request{plan, desktop, ++sequence_};
            requested_ = plan;
            last_desktop_ = desktop;
            // A failed allocation retries locally; foreground keeps live blur.
            retry_after_ = now + std::chrono::milliseconds(33);
          }
        }
      }
      if (Bind(fg, window, desktop))
        ++cached_updates_;
    } catch (...) {
      ++local_errors_;
      try {
        if (active_)
          active_->Hide();
        if (warming_)
          warming_->Hide();
      } catch (...) {
      }
      try {
        Restore(fg);
      } catch (...) {
      }
      requested_ = {};
      retry_after_ = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    }
    // Register only after all brushes have stopped referring to retired slots.
    for (auto const &[generation, index] : retired)
      try {
        generation->RetireAfterCommit(compositor_, index);
      } catch (...) {
      }
  }
  std::string Snapshot() const {
    return "native-background-cache updates=" + std::to_string(updates_) +
           " cached=" + std::to_string(cached_updates_) +
           " publications=" + std::to_string(publications_) +
           " builds=" + std::to_string(shared_->builds.load()) +
           " build_failures=" + std::to_string(shared_->failures.load()) +
           " local_errors=" + std::to_string(local_errors_) +
           " hz=" + std::to_string(hz_) + "\n" +
           (active_ ? active_->Snapshot() : std::string{});
  }
  void Report(FILE *log) const { std::fputs(Snapshot().c_str(), log); }
#ifdef VIEWFLOW_BACKGROUND_CACHE_TESTING
  auto SourceForTest() const { return active_->SourceForTest(); }
  auto SurfaceForTest() const { return surface_; }
  auto RegionForTest() const { return active_->Region(); }
#endif
};
