// AppKit host establishes the responsible application for network/audio privacy.
// The transport remains a child, independent from the window/input application.
#import <AppKit/AppKit.h>
#include <signal.h>

@interface AudioHost : NSObject <NSApplicationDelegate>
@property(strong) NSTask* peer;
@property(strong) dispatch_source_t termination;
@end
@implementation AudioHost
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    self.peer = [NSTask new];
    self.peer.executableURL = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/vf-audio-peer"];
    self.peer.arguments = [NSProcessInfo.processInfo.arguments subarrayWithRange:NSMakeRange(1, NSProcessInfo.processInfo.arguments.count - 1)];
    self.peer.terminationHandler = ^(NSTask* task) {
        (void)task;
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    };
    NSError* error = nil;
    if (![self.peer launchAndReturnError:&error]) {
        fprintf(stderr, "audio host: %s\n", error.localizedDescription.UTF8String);
        [NSApp terminate:nil];
        return;
    }
    signal(SIGTERM, SIG_IGN);
    self.termination = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.termination, ^{ [NSApp terminate:nil]; });
    dispatch_resume(self.termination);
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
    (void)sender;
    if (self.peer.running) { [self.peer terminate]; [self.peer waitUntilExit]; }
    return NSTerminateNow;
}
@end
int main() {
    @autoreleasepool {
        NSApplication* app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AudioHost* host = [AudioHost new];
        app.delegate = host;
        [app run];
    }
    return 0;
}
