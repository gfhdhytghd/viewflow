#pragma once
#import <ApplicationServices/ApplicationServices.h>
namespace viewflow::macos {
// The OS sharing-session button is a capture control, not application content.
inline bool sharing_control_window(pid_t pid, CGRect bounds) {
    auto app=AXUIElementCreateApplication(pid); CFTypeRef value=nullptr;
    AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&value);CFRelease(app);
    if(!value)return false;
    bool found=false;
    for(id item in (__bridge NSArray*)value) {
        auto window=(__bridge AXUIElementRef)item;CFTypeRef position=nullptr,size=nullptr,children=nullptr;
        AXUIElementCopyAttributeValue(window,kAXPositionAttribute,&position);
        AXUIElementCopyAttributeValue(window,kAXSizeAttribute,&size);
        CGPoint p{};CGSize s{};
        const bool matches=position && size && AXValueGetValue((AXValueRef)position,kAXValueTypeCGPoint,&p) && AXValueGetValue((AXValueRef)size,kAXValueTypeCGSize,&s) && CGRectEqualToRect(CGRectMake(p.x,p.y,s.width,s.height),bounds);
        if(position)CFRelease(position);if(size)CFRelease(size);
        if(!matches)continue;
        AXUIElementCopyAttributeValue(window,kAXChildrenAttribute,&children);
        if(children) {
            for(id child in (__bridge NSArray*)children) {
                CFTypeRef title=nullptr;AXUIElementCopyAttributeValue((__bridge AXUIElementRef)child,kAXTitleAttribute,&title);
                if(title){found=CFEqual(title,CFSTR("WindowSharingSessionButton"));CFRelease(title);}
                if(found)break;
            }
            CFRelease(children);
        }
        if(found)break;
    }
    CFRelease(value);return found;
}
}
