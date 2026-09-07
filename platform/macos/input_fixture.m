// User-authorized live input target. Never observes other applications' events.
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

static NSString *output;
static NSMutableArray *events;
static NSMutableString *typed;
static NSRunningApplication *previous;
static NSWindow *window;

static void save(void) {
    NSRect p = [window convertRectToScreen:NSMakeRect(180, 160, 1, 1)];
    NSDictionary *report = @{
        @"target_x": @(p.origin.x),
        @"target_y": @(CGDisplayBounds(CGMainDisplayID()).size.height - p.origin.y),
        @"typed": typed, @"events": events,
        @"shift_held": @(CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, 56)),
        @"left_held": @(CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft))
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:output atomically:YES];
}

@interface InputView : NSView
@end
@implementation InputView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)drawRect:(NSRect)rect {
    (void)rect;
    [[NSColor windowBackgroundColor] setFill]; NSRectFill(self.bounds);
    [@"Viewflow — isolated keyboard / mouse test" drawAtPoint:NSMakePoint(20, 300)
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:20]}];
    [typed drawAtPoint:NSMakePoint(20, 260)
        withAttributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:22 weight:NSFontWeightRegular]}];
    [@"Only test input is recorded. This window closes automatically." drawAtPoint:NSMakePoint(20, 30)
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13]}];
}
- (void)record:(NSEvent *)e {
    if (CGEventGetIntegerValueField(e.CGEvent, kCGEventSourceUserData) != 0x56464c57) return;
    BOOL key = e.type == NSEventTypeKeyDown || e.type == NSEventTypeKeyUp;
    BOOL button = e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeLeftMouseUp;
    [events addObject:@{
        @"type": @(e.type), @"flags": @(e.modifierFlags),
        @"keycode": @(key || e.type == NSEventTypeFlagsChanged ? e.keyCode : 0),
        @"characters": key ? (e.characters ?: @"") : @"",
        @"clicks": @(button ? e.clickCount : 0),
        @"dx": @(e.type == NSEventTypeScrollWheel ? e.scrollingDeltaX : 0),
        @"dy": @(e.type == NSEventTypeScrollWheel ? e.scrollingDeltaY : 0),
        @"x": @(e.locationInWindow.x), @"y": @(e.locationInWindow.y)
    }];
    if (e.type == NSEventTypeKeyDown) [typed appendString:e.characters ?: @""];
    self.needsDisplay = YES;
    save();
}
- (void)keyDown:(NSEvent *)e { [self record:e]; }
- (void)keyUp:(NSEvent *)e { [self record:e]; }
- (void)flagsChanged:(NSEvent *)e { [self record:e]; }
- (void)mouseDown:(NSEvent *)e { [self record:e]; }
- (void)mouseUp:(NSEvent *)e { [self record:e]; }
- (void)mouseDragged:(NSEvent *)e { [self record:e]; }
- (void)mouseMoved:(NSEvent *)e { [self record:e]; }
- (void)scrollWheel:(NSEvent *)e { [self record:e]; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        output = [NSString stringWithUTF8String:argv[1]];
        events = [NSMutableArray array]; typed = [NSMutableString string];
        previous = NSWorkspace.sharedWorkspace.frontmostApplication;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(160, 180, 640, 360)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.title = @"Viewflow input test";
        window.contentView = [[InputView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)];
        window.acceptsMouseMovedEvents = YES;
        [window makeKeyAndOrderFront:nil];
        [window makeFirstResponder:window.contentView];
        [NSApp activate];
        save();
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120];
        [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
            save();
            if ([NSFileManager.defaultManager fileExistsAtPath:[output stringByAppendingString:@".stop"]]
                || [deadline timeIntervalSinceNow] <= 0) {
                [timer invalidate];
                [window orderOut:nil];
                [previous activateWithOptions:0];
                [NSApp terminate:nil];
            }
        }];
        [NSApp run];
    }
    return 0;
}
