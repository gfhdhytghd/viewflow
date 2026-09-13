#pragma once
#import <CoreImage/CoreImage.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <functional>
#include <memory>

namespace viewflow::macos {
// Main-run-loop owned. Auxiliary failures retain the last material and never
// stop the independent-window source or its input connection.
class PopupPreview {
    struct State;
    std::shared_ptr<State> state_;
public:
    PopupPreview(SCDisplay* display, unsigned scale, unsigned fps, std::function<void(CIImage*, CGRect, double)> frame);
    ~PopupPreview();
    void recover(double now);
};

// One passive bottom window per virtual display, fixed below normal windows.
class DesktopBackdrop {
    struct State;
    std::unique_ptr<State> state_;
public:
    DesktopBackdrop();
    ~DesktopBackdrop();
    void update(NSImage* image, CGRect source_bounds);
    void clear();
};

class PopupMaterial {
    struct State;
    std::shared_ptr<State> state_;
public:
    PopupMaterial(SCDisplay* display, SCWindow* window, CGRect bounds, unsigned width, unsigned height,
                  unsigned fps, std::function<void()> changed);
    ~PopupMaterial();
    void shape(CVPixelBufferRef pixels, CGRect body, double timestamp);
    void scene(CIImage* image, CGRect display_bounds, double timestamp);
    void stop();
    CIImage* image() const;
    CGRect bounds() const;
    void recover(double now);
};
}
