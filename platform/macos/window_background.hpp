#pragma once
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#include <memory>
#include "../reverse-common/blur_recipe.hpp"
namespace viewflow::macos {
// Main-thread request/read; capture, allocation and blur run on a private queue.
// Images are immutable snapshots retained by the foreground GPU submission.
class WindowBackground {
    struct State;
    std::shared_ptr<State> state;
    std::optional<reverse::BlurRecipe> configured_recipe;
public:
    explicit WindowBackground(id<MTLDevice> device);
    ~WindowBackground();
    void configure(const std::optional<reverse::BlurRecipe>& recipe);
    void request(NSWindow* window, bool enabled);
    CIImage* image(NSWindow* window, uint64_t& revision);
};
void background_self_test(id<MTLDevice> device);
}
