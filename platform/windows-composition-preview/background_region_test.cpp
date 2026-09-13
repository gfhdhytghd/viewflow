#include "background_region.h"
#include <cassert>
#include <iostream>
using namespace viewflow::background;
int main() {
  Rect desktop{-1920, 0, 6144, 3456};
  const auto kernel = hyprland_support(5, 4);
  assert(kernel == 182);
  Rect window{1000, 700, 1800, 1300};
  auto p = plan(window, desktop, kernel);
  assert(p.bounds.contains(window) &&
         usable(p.bounds, desktop, kernel).contains(window));
  assert(p.bounds == Rect({690, 390, 2110, 1610}));
  assert(!needs_urgent_refresh(p.bounds, window, desktop, kernel));
  for (int delta = -64; delta <= 64; ++delta) {
    Rect moved = window;
    moved.left += delta;
    moved.right += delta;
    assert(usable(p.bounds, desktop, kernel).contains(moved));
    auto [x, y] = brush_offset(p.bounds, moved);
    assert(moved.left + x == p.bounds.left && moved.top + y == p.bounds.top);
  }
  Rect moved{1100, 700, 1900, 1300};
  assert(needs_urgent_refresh(p.bounds, moved, desktop, kernel));
  assert(usable(p.bounds, desktop, kernel)
             .contains(moved)); // prefetch before miss
  Rect resized{1000, 700, 1850, 1320};
  assert(usable(p.bounds, desktop, kernel).contains(resized));
  assert(brush_offset(p.bounds, resized) == brush_offset(p.bounds, window));
  auto fast = plan(window, desktop, kernel, 6000, -3000);
  assert(fast.motion_x == 400 && fast.motion_y == 200);
  assert(fast.bounds.contains(p.bounds));
  Rect edge{-1924, -4, -1076, 604};
  auto clipped = plan(edge, desktop, kernel);
  assert(clipped.bounds.left == desktop.left &&
         clipped.bounds.top == desktop.top);
  assert(usable(clipped.bounds, desktop, kernel).contains(clipped.visible));
  assert(!needs_urgent_refresh(clipped.bounds, edge, desktop, kernel));
  assert((brush_offset(clipped.bounds, edge) ==
          std::pair<int64_t, int64_t>(4, 4)));
  assert(!plan({-2000, 0, 20000, 1000}, {-3000, 0, 25000, 10000}, kernel)
              .fits_texture);
  assert(plan({10000, 0, 11000, 1000}, desktop, kernel).visible.empty());
  // A full-screen proxy's transparent border can extend four pixels outside
  // its monitor. Neither that border nor velocity may expand the cache into
  // another monitor or gaps in the virtual desktop's bounding rectangle.
  const Rect display{0, 0, 3840, 2400};
  for (int velocity : {-12000, 0, 12000}) {
    const auto screen =
        plan({-4, -4, 3844, 2404}, display, kernel, velocity, velocity);
    assert(screen.bounds == display);
    assert(screen.fits_texture);
  }
  unsigned partitions = 0;
  auto area = [](auto r) {
    return std::max(0.0f, r[2] - r[0]) * std::max(0.0f, r[3] - r[1]);
  };
  for (float x = -12; x <= 12; x += .5f)
    for (float y = -12; y <= 12; y += .5f) {
      const auto parts = display_partition(10, 10, {x, y, x + 8, y + 8});
      float total = 0;
      for (size_t i = 0; i < parts.size(); ++i) {
        total += area(parts[i]);
        assert(parts[i][0] >= 0 && parts[i][1] >= 0 && parts[i][2] <= 10 &&
               parts[i][3] <= 10);
        for (size_t j = i + 1; j < parts.size(); ++j)
          assert(area(std::array<float, 4>{
                     std::max(parts[i][0], parts[j][0]),
                     std::max(parts[i][1], parts[j][1]),
                     std::min(parts[i][2], parts[j][2]),
                     std::min(parts[i][3], parts[j][3])}) == 0);
      }
      assert(total == 100);
      ++partitions;
    }
  // Resize/move generations are simulated geometry only; no desktop input.
  unsigned checked = 0;
  for (int x = -1800; x < 5000; x += 71)
    for (int y = 0; y < 2200; y += 79) {
      Rect r{x, y, x + 800, y + 600};
      auto q = plan(r, desktop, kernel, 900, 300);
      assert(q.fits_texture);
      assert(usable(q.bounds, desktop, kernel).contains(q.visible));
      assert(!needs_urgent_refresh(q.bounds, r, desktop, kernel));
      ++checked;
    }
  std::cout << "PASS background geometry cases=" << checked
            << " partitions=" << partitions << " kernel=" << kernel
            << " input_injected=0\n";
}
