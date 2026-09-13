#pragma once
#import <CoreGraphics/CoreGraphics.h>
#include <optional>
namespace viewflow::macos {
inline constexpr unsigned parking_vendor = 0x5646;
inline constexpr unsigned parking_product = 0x5746;
bool is_parking_display(CGDirectDisplayID display);
std::optional<bool> remote_window_needed(CGRect bounds);
CGPoint backing_position(CGPoint requested, CGSize size);
int run_parking_display(int width, int height, int x, int y);
}
