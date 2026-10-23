#include "desktop_layout.h"
#include <cassert>

using namespace viewflow;
int main() {
  const vfgp::DesktopRect captured{-120000,-80000,1440000,960000};
  const std::optional<vfgp::DesktopRect> body=vfgp::DesktopRect{0,0,1200000,800000};
  const vfgp::DesktopRect snapped{1920000,0,960000,1040000};
  const auto expanded=windows_preview::FullForBody(snapped,captured,body);
  assert(expanded.x_millidip==1800000 && expanded.y_millidip==-80000 && expanded.width_millidip==1200000 && expanded.height_millidip==1200000);
  const auto recovered=windows_preview::BodyForFull(expanded,captured,body);
  assert(recovered.x_millidip==snapped.x_millidip && recovered.y_millidip==snapped.y_millidip && recovered.width_millidip==snapped.width_millidip && recovered.height_millidip==snapped.height_millidip);

  windows_preview::DesktopDisplay display{1000, 2000, -1920, 0,
                                          1920, 1080, 1500};
  assert(windows_preview::ValidDisplay(display));
  const vfgp::DesktopRect window{-499'000, 2500, 3'500'000, 1'000'000};
  const auto slice = windows_preview::SliceForDisplay(window, display);
  assert(slice && slice->global.x_millidip == 1000 &&
         slice->global.y_millidip == 2500);
  assert(slice->physical.x == -1920 && slice->physical.y == 0 &&
         slice->physical.width == 1920);
  assert(slice->full_physical_width == 5250 && slice->crop_x == 750);
  const auto whole = windows_preview::FullWindowForSlice(*slice);
  assert(whole && whole->x == -2670 && whole->width == 5250);
  auto clip = windows_preview::ClipPhysicalWindow(*whole, display);
  assert(clip.x == 750 && clip.width == 1920);
  auto moved = *whole; moved.x += 300;
  clip = windows_preview::ClipPhysicalWindow(moved, display);
  assert(moved.width == 5250 && clip.x == 450 && clip.width == 1920);
  // Moving the visible portion translates the entire rectangle without
  // changing width; cropping changes independently as it crosses the seam.
  moved.x += 450;
  clip = windows_preview::ClipPhysicalWindow(moved, display);
  assert(clip.x == 0 && moved.width == 5250);
  moved.x = display.physical_x + int32_t(display.physical_width);
  assert(windows_preview::ClipPhysicalWindow(moved, display).width == 0);
  const auto point =
      windows_preview::ScreenToGlobalMillidip(-1000, 100, display);
  assert(point && point->first == 614'333 && point->second == 68'666);
  const auto viewport = windows_preview::DisplayGlobalRect(display);
  assert(viewport && viewport->width_millidip == 1'280'000 && viewport->height_millidip == 720'000);
  display.scale_milli = 1250;
  assert(windows_preview::DisplayGlobalRect(display)->width_millidip == 1'536'000);
  display.scale_milli = 1500;
  display.physical_width = 2560;
  assert(windows_preview::DisplayGlobalRect(display)->width_millidip == 1'706'666);
  display.physical_width = 1920;
  assert(!windows_preview::MillidipToPixelsCeil(UINT64_MAX, 1500));
  assert(!windows_preview::ScreenToGlobalMillidip(0, 0, display));
  // Edge touching does not leak one physical pixel onto a neighbouring peer.
  assert(!windows_preview::SliceForDisplay({-2'999'000, 2000, 3'000'000, 1},
                                           display));
  assert(!windows_preview::ValidDisplay({0, 0, 0, 0, 1, 1, 0}));
}
