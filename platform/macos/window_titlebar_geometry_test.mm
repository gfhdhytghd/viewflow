#import <AppKit/AppKit.h>
#include <cassert>
#include <cmath>

int main() {
    @autoreleasepool {
        // Class-only geometry queries: no window, focus, capture or input.
        const auto style = NSWindowStyleMaskTitled | NSWindowStyleMaskResizable;
        const auto content = NSMakeRect(-3072, -299, 551.5, 285.5);
        const auto frame = [NSWindow frameRectForContentRect:content styleMask:style];
        const auto decoded = [NSWindow contentRectForFrameRect:frame styleMask:style];
        assert(NSEqualRects(decoded, content));
        assert(frame.size.height > content.size.height);
        // Wire size belongs to video content; native chrome stays outside it.
        assert(std::lround(decoded.size.width * 2) == 1103);
        assert(std::lround(decoded.size.height * 2) == 571);
        const auto pointer = NSMakePoint(NSMidX(content), NSMidY(content));
        assert(std::abs((pointer.x - decoded.origin.x) / decoded.size.width - .5) < 1e-9);
        assert(std::abs((NSMaxY(decoded) - pointer.y) / decoded.size.height - .5) < 1e-9);
    }
}
