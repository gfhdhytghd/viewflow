#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include "policy.hpp"
#include <cstdio>
#include <fcntl.h>
#include <signal.h>
#include <sys/file.h>
#include <unistd.h>
#include <notify.h>

namespace vr=viewflow::recall;
namespace {
struct Screen { CGDirectDisplayID id{}; vr::Rect bounds{},work{}; };
std::vector<Screen> physical_screens() {
    std::vector<Screen> result;
    for(NSScreen* screen in NSScreen.screens) {
        const auto id=CGDirectDisplayID([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
        // This identifies Viewflow parking displays regardless of their names/origins.
        if(CGDisplayVendorNumber(id)==0x5646 && CGDisplayModelNumber(id)==0x5746)continue;
        const auto b=CGDisplayBounds(id);const NSRect f=screen.frame,v=screen.visibleFrame;
        result.push_back({id,{b.origin.x,b.origin.y,b.size.width,b.size.height},
            {b.origin.x+v.origin.x-f.origin.x,b.origin.y+NSMaxY(f)-NSMaxY(v),v.size.width,v.size.height}});
    }
    return result;
}
CFTypeRef attribute(AXUIElementRef window,CFStringRef name) {
    CFTypeRef value=nullptr;if(AXUIElementCopyAttributeValue(window,name,&value)!=kAXErrorSuccess)return nullptr;return value;
}
std::optional<vr::Rect> bounds(AXUIElementRef window) {
    CFTypeRef position=attribute(window,kAXPositionAttribute),size=attribute(window,kAXSizeAttribute);
    CGPoint p{};CGSize s{};
    const bool ok=position&&size&&CFGetTypeID(position)==AXValueGetTypeID()&&CFGetTypeID(size)==AXValueGetTypeID()&&
        AXValueGetValue((AXValueRef)position,kAXValueTypeCGPoint,&p)&&AXValueGetValue((AXValueRef)size,kAXValueTypeCGSize,&s);
    if(position)CFRelease(position);if(size)CFRelease(size);
    vr::Rect r{p.x,p.y,s.width,s.height};return ok&&r.valid()?std::optional(r):std::nullopt;
}
bool boolean(AXUIElementRef window,CFStringRef name) {
    CFTypeRef value=attribute(window,name);const bool result=value&&CFEqual(value,kCFBooleanTrue);if(value)CFRelease(value);return result;
}
bool foreign_proxy(NSRunningApplication* app) {
    NSString* executable=app.executableURL.lastPathComponent ?: @"";
    return [executable hasPrefix:@"viewflow-macos-windows"] || [executable isEqualToString:@"viewflow-window-recall"];
}
CGDirectDisplayID recent_physical=0;
void observe_focus(const std::vector<Screen>& screens) {
    if(!AXIsProcessTrusted())return;
    NSRunningApplication* focused=NSWorkspace.sharedWorkspace.frontmostApplication;
    if(!focused)return;
    AXUIElementRef app=AXUIElementCreateApplication(focused.processIdentifier);AXUIElementSetMessagingTimeout(app,0.15f);
    CFTypeRef window=attribute(app,kAXFocusedWindowAttribute);
    if(window&&CFGetTypeID(window)==AXUIElementGetTypeID()) {
        if(auto r=bounds((AXUIElementRef)window))for(const auto& s:screens)
            if(s.bounds.contains(r->x+r->width/2,r->y+r->height/2))recent_physical=s.id;
    }
    if(window)CFRelease(window);CFRelease(app);
}
int recall(bool check) {
    if(!AXIsProcessTrusted()) {std::fputs("recall requires Accessibility permission for Viewflow\n",stderr);return 3;}
    auto screens=physical_screens();observe_focus(screens);
    if(screens.empty()) {std::fputs("recall unavailable: no physical screen\n",stderr);return 4;}
    const Screen* target=&screens.front();for(auto& s:screens)if(s.id==CGMainDisplayID())target=&s;
    for(auto& s:screens)if(s.id==recent_physical)target=&s;
    std::vector<vr::Rect> physical;for(auto& s:screens)physical.push_back(s.bounds);
    unsigned eligible=0,moved=0,failed=0;
    for(NSRunningApplication* running in NSWorkspace.sharedWorkspace.runningApplications) {
        if(running.terminated || running.activationPolicy==NSApplicationActivationPolicyProhibited || foreign_proxy(running))continue;
        AXUIElementRef app=AXUIElementCreateApplication(running.processIdentifier);AXUIElementSetMessagingTimeout(app,0.2f);
        CFTypeRef value=attribute(app,kAXWindowsAttribute);
        if(value&&CFGetTypeID(value)==CFArrayGetTypeID()) {
            CFArrayRef windows=(CFArrayRef)value;
            for(CFIndex i=0;i<CFArrayGetCount(windows);++i) {
                auto window=(AXUIElementRef)CFArrayGetValueAtIndex(windows,i);
                CFTypeRef role=attribute(window,kAXRoleAttribute);
                const bool is_window=role&&CFEqual(role,kAXWindowRole);if(role)CFRelease(role);
                // Attached sheets follow their parent through the native window manager.
                if(!is_window || boolean(window,CFSTR("AXFullScreen")) || boolean(window,kAXMinimizedAttribute))continue;
                auto original=bounds(window);if(!original||!vr::needs_recall(*original,physical))continue;
                const auto dest=vr::placement(*original,target->work,eligible++);
                if(check)continue;
                bool ok=true;
                if(dest.width!=original->width || dest.height!=original->height) {
                    CGSize size{dest.width,dest.height};AXValueRef v=AXValueCreate(kAXValueTypeCGSize,&size);
                    ok=AXUIElementSetAttributeValue(window,kAXSizeAttribute,v)==kAXErrorSuccess;CFRelease(v);
                }
                CGPoint point{dest.x,dest.y};AXValueRef v=AXValueCreate(kAXValueTypeCGPoint,&point);
                const bool positioned=AXUIElementSetAttributeValue(window,kAXPositionAttribute,v)==kAXErrorSuccess;CFRelease(v);
                if(positioned)++moved;if(!ok||!positioned)++failed;
            }
        }
        if(value)CFRelease(value);CFRelease(app);
    }
    std::printf("recall physical=%zu eligible=%u moved=%u failed=%u dry_run=%u\n",screens.size(),eligible,moved,failed,unsigned(check));std::fflush(stdout);
    return failed?1:0;
}
struct Watcher { bool held=false; pid_t parent=0; int notification=-1; };
OSStatus hotkey(EventHandlerCallRef,EventRef event,void* data) {
    auto& watcher=*static_cast<Watcher*>(data);
    if(GetEventKind(event)==kEventHotKeyReleased)watcher.held=false;
    else if(!watcher.held) {watcher.held=true;@autoreleasepool {recall(false);}}
    return noErr;
}
void tick(EventLoopTimerRef,void* data) {
    @autoreleasepool {
        auto& watcher=*static_cast<Watcher*>(data);
        if(watcher.parent>0 && kill(watcher.parent,0)<0 && errno==ESRCH) {std::exit(0);}
        observe_focus(physical_screens());
        int changed=0;
        if(watcher.notification>=0 && notify_check(watcher.notification,&changed)==NOTIFY_STATUS_OK && changed)recall(false);
    }
}
UInt32 keycode(char letter) {
    constexpr UInt32 codes[]={kVK_ANSI_A,kVK_ANSI_B,kVK_ANSI_C,kVK_ANSI_D,kVK_ANSI_E,kVK_ANSI_F,kVK_ANSI_G,kVK_ANSI_H,kVK_ANSI_I,kVK_ANSI_J,kVK_ANSI_K,kVK_ANSI_L,kVK_ANSI_M,kVK_ANSI_N,kVK_ANSI_O,kVK_ANSI_P,kVK_ANSI_Q,kVK_ANSI_R,kVK_ANSI_S,kVK_ANSI_T,kVK_ANSI_U,kVK_ANSI_V,kVK_ANSI_W,kVK_ANSI_X,kVK_ANSI_Y,kVK_ANSI_Z};
    return codes[letter-'A'];
}
}
int main(int argc,const char** argv) {
    @autoreleasepool {
        try {
            std::string mode="--watch";vr::Shortcut shortcut;Watcher watcher;
            for(int i=1;i<argc;++i) {
                std::string_view arg=argv[i];
                if(arg=="--shortcut"&&i+1<argc)shortcut=vr::parse_shortcut(argv[++i]);
                else if(arg=="--parent"&&i+1<argc)watcher.parent=pid_t(std::stol(argv[++i]));
                else if(arg=="--once"||arg=="--watch"||arg=="--check"||arg=="--help"||arg=="--validate-shortcut")mode=arg;
                else throw std::invalid_argument("Unknown recall argument");
            }
            if(mode=="--help") {std::puts("viewflow-window-recall [--watch|--once|--check|--validate-shortcut] [--shortcut Ctrl+Alt+Shift+H] [--parent PID]");return 0;}
            if(mode=="--validate-shortcut") {std::puts(vr::format_shortcut(shortcut).c_str());return 0;}
            [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
            if(mode=="--check")return recall(true);
            NSURL* directory=[[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject] URLByAppendingPathComponent:@"Viewflow/run"];
            [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
            const int lock=open([[directory URLByAppendingPathComponent:@"window-recall.lock"] fileSystemRepresentation],O_CREAT|O_RDWR|O_CLOEXEC,0600);
            if(lock<0)throw std::runtime_error("Cannot open recall watcher lock");
            const std::string notification="org.viewflow.window-recall."+std::to_string(getuid());
            if(flock(lock,LOCK_EX|LOCK_NB)<0) {
                close(lock);
                if(mode=="--once") {notify_post(notification.c_str());std::puts("recall queued");return 0;}
                std::fputs("recall watcher already running\n",stderr);return 2;
            }
            if(mode=="--once") {const int result=recall(false);close(lock);return result;}
            notify_register_check(notification.c_str(),&watcher.notification);
            int initial=0;notify_check(watcher.notification,&initial);
            const UInt32 modifiers=((shortcut.modifiers&vr::control)?controlKey:0)|((shortcut.modifiers&vr::alt)?optionKey:0)|
                ((shortcut.modifiers&vr::shift)?shiftKey:0)|((shortcut.modifiers&vr::super)?cmdKey:0);
            EventTypeSpec types[]={{kEventClassKeyboard,kEventHotKeyPressed},{kEventClassKeyboard,kEventHotKeyReleased}};
            EventHandlerRef handler=nullptr;EventHotKeyRef key=nullptr;EventLoopTimerRef timer=nullptr;
            OSStatus status=InstallApplicationEventHandler(hotkey,2,types,&watcher,&handler);
            if(status==noErr)status=RegisterEventHotKey(keycode(shortcut.letter),modifiers,{0x56465248,1},GetApplicationEventTarget(),0,&key);
            if(status!=noErr) {if(handler)RemoveEventHandler(handler);if(watcher.notification>=0)notify_cancel(watcher.notification);close(lock);std::fprintf(stderr,"recall shortcut unavailable: %d\n",int(status));return 2;}
            InstallEventLoopTimer(GetMainEventLoop(),0,0.25,tick,&watcher,&timer);
            std::printf("recall ready shortcut=%s\n",vr::format_shortcut(shortcut).c_str());std::fflush(stdout);
            [NSApp run];
            if(timer)RemoveEventLoopTimer(timer);UnregisterEventHotKey(key);RemoveEventHandler(handler);
            if(watcher.notification>=0)notify_cancel(watcher.notification);close(lock);return 0;
        } catch(const std::exception& e) {std::fprintf(stderr,"recall: %s\n",e.what());return 1;}
    }
}
