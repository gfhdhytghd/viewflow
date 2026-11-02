#pragma once
#import <AppKit/AppKit.h>
#include "../reverse-common/work_area.hpp"
#include "../reverse-common/work_area_math.hpp"
#include "window_native.hpp"
#include "window_parking.hpp"
namespace viewflow::macos {
inline std::vector<reverse::WorkAreaDisplay> screen_work_areas(const Options& options) {
    std::vector<reverse::WorkAreaDisplay> result;
    const auto top=NSScreen.screens.firstObject.frame.size.height;
    for(NSScreen* screen in NSScreen.screens) {
        NSNumber* number=screen.deviceDescription[@"NSScreenNumber"];
        if(!number || is_parking_display(number.unsignedIntValue))continue;
        const auto f=screen.frame,v=screen.visibleFrame;
        if(NSIsEmptyRect(f) || NSIsEmptyRect(v))continue;
        NSEdgeInsets safe=NSEdgeInsetsMake(0,0,0,0);
        if(@available(macOS 12.0,*))safe=screen.safeAreaInsets;
        const auto insets=reverse::visibleInsets({f.origin.x,f.origin.y,f.size.width,f.size.height},
            {v.origin.x,v.origin.y,v.size.width,v.size.height},{safe.top,safe.right,safe.bottom,safe.left});
        if(insets[0]+insets[2]>=f.size.height || insets[1]+insets[3]>=f.size.width)continue;
        const auto plane=reverse::projectScreen({f.origin.x,f.origin.y,f.size.width,f.size.height},top,options.origin_x,options.origin_y,options.scale);
        result.push_back({number.unsignedLongLongValue,{plane.x,plane.y,plane.width,plane.height,
            insets[0]*options.scale,insets[1]*options.scale,insets[2]*options.scale,insets[3]*options.scale}});
    }
    return result;
}
inline std::string work_area_preferences() {
    // Dock writes its domain atomically; attributes also catch auto-hide,
    // orientation, tile size and magnification changes without changing prefs.
    std::string fingerprint;
    for(NSString* name in @[@"com.apple.dock.plist",@".GlobalPreferences.plist",@"com.apple.controlcenter.plist"]) {
        NSString* path=[NSHomeDirectory() stringByAppendingPathComponent:[@"Library/Preferences/" stringByAppendingString:name]];
        NSDictionary* attributes=[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        fingerprint+=std::to_string([attributes[NSFileModificationDate] timeIntervalSince1970])+"/"+
            std::to_string([attributes[NSFileSize] unsignedLongLongValue])+"/"+
            std::to_string([attributes[NSFileSystemFileNumber] unsignedLongLongValue])+";";
    }
    return fingerprint;
}
inline std::array<int64_t,4> backing_rect(NSRect rect,double scale) {
    return {int64_t(std::llround(rect.origin.x*scale)),int64_t(std::llround(rect.origin.y*scale)),
        int64_t(std::llround(rect.size.width*scale)),int64_t(std::llround(rect.size.height*scale))};
}
}
