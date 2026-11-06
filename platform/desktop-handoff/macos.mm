#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include "pipe.hpp"
#include "../reverse-common/scroll_units.hpp"
#include "../macos/window_keys.hpp"
#include <csignal>
namespace h=viewflow::handoff;
namespace {
constexpr int64_t marker=0x56464831;
h::Core* core{};h::Output* output{};CFMachPortRef tap{};CGPoint saved{};
std::set<int> native_keys;
viewflow::reverse::ScrollPointAccumulator scroll;
CGEventFlags flags() {
    CGEventFlags f=0;
    for(int k:native_keys) {
        if(k==29 || k==97)f|=kCGEventFlagMaskControl;
        if(k==42 || k==54)f|=kCGEventFlagMaskShift;
        if(k==56 || k==100)f|=kCGEventFlagMaskAlternate;
        if(k==125 || k==126)f|=kCGEventFlagMaskCommand;
    }
    return f;
}
void post(h::Input e) {
    CGEventRef event=nullptr;
    if(h::kind(e)==4) {
        const auto key=viewflow::macos::mac_key(e.a);
        if(!key)throw std::runtime_error("unsupported physical key");
        if(e.b)native_keys.insert(e.a);else native_keys.erase(e.a);
        event=CGEventCreateKeyboardEvent(nullptr,CGKeyCode(*key),e.b!=0);
    } else if(h::kind(e)==1 || h::kind(e)==2) {
        CGEventRef probe=CGEventCreate(nullptr);
        if(!probe)throw std::runtime_error("cannot read cursor position");
        CGPoint p=CGEventGetLocation(probe);CFRelease(probe);
        CGEventType type=kCGEventMouseMoved;CGMouseButton button=kCGMouseButtonLeft;
        if(h::kind(e)==1) {
            p=CGPointMake(core->local.x+e.a/1000.0,core->local.y+e.b/1000.0);
            if(core->receivedButtons.contains(272))type=kCGEventLeftMouseDragged;
            else if(core->receivedButtons.contains(273)){type=kCGEventRightMouseDragged;button=kCGMouseButtonRight;}
            else if(!core->receivedButtons.empty()){type=kCGEventOtherMouseDragged;button=kCGMouseButtonCenter;}
        } else {
            if(e.a==272)type=e.b?kCGEventLeftMouseDown:kCGEventLeftMouseUp;
            else if(e.a==273){button=kCGMouseButtonRight;type=e.b?kCGEventRightMouseDown:kCGEventRightMouseUp;}
            else {button=CGMouseButton(e.a-272);type=e.b?kCGEventOtherMouseDown:kCGEventOtherMouseUp;}
        }
        event=CGEventCreateMouseEvent(nullptr,type,p,button);
    } else if(h::kind(e)==3) {
        const auto units=viewflow::reverse::decode_scroll(e.a,e.b,e.c,e.d);
        if(!units)throw std::runtime_error("invalid scroll units");
        const int amount=units->precise?scroll.take(e.a,e.b):int(std::lround(units->distance));
        event=CGEventCreateScrollWheelEvent(nullptr,e.c?kCGScrollEventUnitPixel:kCGScrollEventUnitLine,2,
            e.a?0:int(std::lround(amount)),e.a?int(std::lround(amount)):0);
        if(event && e.c) {
            CGEventSetIntegerValueField(event,kCGScrollWheelEventIsContinuous,1);
            CGEventSetIntegerValueField(event,kCGScrollWheelEventScrollPhase,scroll.phase(e.a,e.d!=0));
        } else if(event) {
            CGEventSetDoubleValueField(event,e.a?kCGScrollWheelEventFixedPtDeltaAxis2:kCGScrollWheelEventFixedPtDeltaAxis1,units->distance);
        }
    } else return;
    if(!event)throw std::runtime_error("cannot create input event");
    CGEventSetFlags(event,flags());CGEventSetIntegerValueField(event,kCGEventSourceUserData,marker);
    CGEventPost(kCGSessionEventTap,event);CFRelease(event);
}
void capture(bool active) {
    if(active) {
        CGEventRef event=CGEventCreate(nullptr);
        if(!event)throw std::runtime_error("cannot save cursor position");
        saved=CGEventGetLocation(event);CFRelease(event);
        CGDisplayHideCursor(kCGDirectMainDisplay);
        CGAssociateMouseAndMouseCursorPosition(false);
    } else {
        CGAssociateMouseAndMouseCursorPosition(true);
        saved.x=std::clamp(core->remote.x+core->x,core->local.x+1,core->local.x+core->local.w-2);
        saved.y=std::clamp(core->remote.y+core->y,core->local.y+1,core->local.y+core->local.h-2);
        CGWarpMouseCursorPosition(saved);CGDisplayShowCursor(kCGDirectMainDisplay);
    }
}
void fail() {try{core->reset();}catch(...){} try{output->send(h::message(h::fault));}catch(...){} }
CGEventRef callback(CGEventTapProxy,CGEventType type,CGEventRef e,void*) {
    if(type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput) {
        fail();CGEventTapEnable(tap,true);return e;
    }
    if(CGEventGetIntegerValueField(e,kCGEventSourceUserData)==marker)return e;
    // Other synthetic sources (window presenters, accessibility tools) are not
    // physical edge triggers either. HID hardware events have source PID zero.
    const bool injected=CGEventGetIntegerValueField(e,kCGEventSourceUnixProcessID)!=0;
    if(injected)return e;
    try {
        bool swallow=false;
        if(type==kCGEventMouseMoved || type==kCGEventLeftMouseDragged || type==kCGEventRightMouseDragged || type==kCGEventOtherMouseDragged) {
            const auto p=CGEventGetLocation(e);
            swallow=core->motion(p.x,p.y,CGEventGetIntegerValueField(e,kCGMouseEventDeltaX),CGEventGetIntegerValueField(e,kCGMouseEventDeltaY));
        } else if(type==kCGEventKeyDown || type==kCGEventKeyUp || type==kCGEventFlagsChanged) {
            const auto key=unsigned(CGEventGetIntegerValueField(e,kCGKeyboardEventKeycode));
            if(const auto code=viewflow::macos::evdev_key(key)) {
                const bool down=type==kCGEventFlagsChanged?CGEventSourceKeyState(kCGEventSourceStateHIDSystemState,CGKeyCode(key)):type==kCGEventKeyDown;
                swallow=core->input(h::message(4,int(*code),down));
            } else swallow=core->outgoing;
        } else if(type==kCGEventScrollWheel) {
            NSEvent* native=[NSEvent eventWithCGEvent:e];
            const bool precise=native.hasPreciseScrollingDeltas;
            const bool end=precise && ((native.phase|native.momentumPhase)&(NSEventPhaseEnded|NSEventPhaseCancelled));
            for(int axis=0;axis<2;++axis) {
                const double amount=(axis?native.scrollingDeltaX:native.scrollingDeltaY)*(precise?1000:120);
                if(amount || end)swallow=core->input(h::message(3,axis,int(std::lround(amount)),precise,end)) || swallow;
            }
        } else {
            int button=0;bool down=false;
            switch(type) {
            case kCGEventLeftMouseDown:down=true;[[fallthrough]];case kCGEventLeftMouseUp:button=272;break;
            case kCGEventRightMouseDown:down=true;[[fallthrough]];case kCGEventRightMouseUp:button=273;break;
            case kCGEventOtherMouseDown:down=true;[[fallthrough]];case kCGEventOtherMouseUp:button=272+int(CGEventGetIntegerValueField(e,kCGMouseEventButtonNumber));break;
            default:break;
            }
            if(button)swallow=core->input(h::message(2,button,down));
        }
        return swallow?nullptr:e;
    }catch(...){fail();return e;}
}
}
int main(int argc,char** argv) {
    @autoreleasepool {
        try {
            if(argc==2 && std::string(argv[1])=="--self-test")return h::self_test();
            const auto [local,remote]=h::geometry(argc,argv);
            std::signal(SIGPIPE,SIG_IGN);
            std::signal(SIGINT,SIG_IGN);std::signal(SIGTERM,SIG_IGN);
            if(!CGPreflightPostEventAccess())
                throw std::runtime_error("Accessibility / Input Monitoring permission missing; other lanes remain available");
            h::Core state(local,remote);core=&state;
            for(auto [key,code]:viewflow::macos::key_pairs)
                if(CGEventSourceKeyState(kCGEventSourceStateHIDSystemState,CGKeyCode(key)))state.physicalKeys.insert(int(code));
            for(int button=0;button<5;++button)
                if(CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,CGMouseButton(button)))state.physicalButtons.insert(272+button);
            h::Output writer;output=&writer;
            state.send=[&](h::Input e){writer.send(e);};state.inject=post;state.capture=capture;
            const auto loop=CFRunLoopGetCurrent();
            writer.failed=[loop]{CFRunLoopStop(loop);};
            CGEventMask mask=0;
            for(auto t:{kCGEventMouseMoved,kCGEventLeftMouseDragged,kCGEventRightMouseDragged,kCGEventOtherMouseDragged,
                kCGEventLeftMouseDown,kCGEventLeftMouseUp,kCGEventRightMouseDown,kCGEventRightMouseUp,
                kCGEventOtherMouseDown,kCGEventOtherMouseUp,kCGEventKeyDown,kCGEventKeyUp,kCGEventFlagsChanged,kCGEventScrollWheel})mask|=CGEventMaskBit(t);
            tap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,mask,callback,nullptr);
            if(!tap)std::fprintf(stderr,"handoff sender unavailable: Input Monitoring; receiver remains available\n");
            auto source=tap?CFMachPortCreateRunLoopSource(nullptr,tap,0):nullptr;
            if(source){CFRunLoopAddSource(loop,source,kCFRunLoopCommonModes);CGEventTapEnable(tap,true);}
            writer.send(h::message(h::capabilities,tap!=nullptr,1));
            // EOF belongs to this worker; it restores capture and held state.
            std::thread reader([loop] {
                try {
                    std::vector<uint8_t> bytes;
                    while(viewflow::reverse::read_record(0,bytes)) {
                        const auto event=h::decode(bytes);
                        CFRunLoopPerformBlock(loop,kCFRunLoopCommonModes,^{try{core->command(event);}catch(...){fail();}});
                        CFRunLoopWakeUp(loop);
                    }
                }catch(...){}
                CFRunLoopPerformBlock(loop,kCFRunLoopCommonModes,^{CFRunLoopStop(loop);});CFRunLoopWakeUp(loop);
            });
            CFRunLoopRun();state.reset();
            if(tap)CGEventTapEnable(tap,false);
            if(source){CFRunLoopRemoveSource(loop,source,kCFRunLoopCommonModes);CFRelease(source);}
            if(tap)CFRelease(tap);
            // The transport closes stdin before waiting for this process.
            reader.join();return 0;
        }catch(const std::exception& e){std::fprintf(stderr,"handoff unavailable: %s\n",e.what());return 1;}
    }
}
