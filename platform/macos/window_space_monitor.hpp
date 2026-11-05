#pragma once
#include "window_space_transition.hpp"
#include "window_parking.hpp"
#import <AppKit/AppKit.h>
#include <atomic>
#include <dlfcn.h>
#include <mutex>

namespace viewflow::macos {
struct SpaceSignals {
    bool animating = false;
    std::map<uint32_t, uint64_t> spaces;
};
inline SpaceSignals space_signals() {
    // Optional, read-only SkyLight SPI; never link private symbols directly.
    static void* library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    auto symbol = [](void* handle, const char* sls, const char* cgs) -> void* {
        if (!handle) return nullptr;
        if (auto* result = dlsym(handle, sls)) return result;
        return dlsym(handle, cgs);
    };
    using Connection = int (*)();
    using Animating = bool (*)(int, CFStringRef);
    using Current = uint64_t (*)(int, CFStringRef);
    static auto connection = reinterpret_cast<Connection>(symbol(library, "SLSMainConnectionID", "CGSMainConnectionID"));
    static auto animating = reinterpret_cast<Animating>(symbol(library, "SLSManagedDisplayIsAnimating", "CGSManagedDisplayIsAnimating"));
    static auto current = reinterpret_cast<Current>(symbol(library, "SLSManagedDisplayGetCurrentSpace", "CGSManagedDisplayGetCurrentSpace"));
    SpaceSignals result;
    if (!connection) return result;
    CGDirectDisplayID displays[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) return result;
    const int cid = connection();
    for (uint32_t i=0; i<count; ++i) {
        if (is_parking_display(displays[i])) continue;
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displays[i]);
        if (!uuid) continue;
        CFStringRef name = CFUUIDCreateString(nullptr, uuid); CFRelease(uuid);
        if (animating) result.animating |= animating(cid, name);
        if (current) result.spaces.emplace(displays[i], current(cid, name));
        CFRelease(name);
    }
    return result;
}
inline std::vector<SpaceWindow> space_windows(NSArray* items) {
    CGDirectDisplayID displays[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) return {};
    std::vector<SpaceWindow> windows;
    for (NSDictionary* item in items) {
        if (![item[(__bridge NSString*)kCGWindowIsOnscreen] boolValue] ||
            [item[(__bridge NSString*)kCGWindowLayer] intValue] != 0) continue;
        CGRect r{};
        NSDictionary* geometry = item[(__bridge NSString*)kCGWindowBounds];
        if (!geometry || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)geometry, &r)) continue;
        for (uint32_t i=0; i<count; ++i) {
            if (is_parking_display(displays[i]) || !CGRectIntersectsRect(r, CGDisplayBounds(displays[i]))) continue;
            const uint64_t id = ([item[(__bridge NSString*)kCGWindowOwnerPID] unsignedLongLongValue] << 32) |
                [item[(__bridge NSString*)kCGWindowNumber] unsignedIntValue];
            windows.push_back({id, r.origin.x, r.origin.y, r.size.width, r.size.height, displays[i]}); break;
        }
    }
    return windows;
}
class SpaceMonitor {
    SpaceTransitionGate gate;
    std::atomic<bool> notified{false}, blocked{false};
    std::mutex mutex;
    double next_sample = 0;
    SpaceSignals signals;
    id observer;
public:
    SpaceMonitor() {
        observer = [NSWorkspace.sharedWorkspace.notificationCenter
            addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:nil
            usingBlock:^(NSNotification*) { notified.store(true); blocked.store(true); }];
    }
    ~SpaceMonitor() { [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer]; }
    bool holding() const { return blocked.load() || notified.load(); }
    bool sample(NSArray* items = nil) {
        std::lock_guard lock(mutex);
        const double now = NSProcessInfo.processInfo.systemUptime;
        if (now < next_sample && !items) return holding();
        if (now >= next_sample) {
            next_sample = now + .05; // Reuse caller cadence; no timer or polling thread.
            signals = space_signals();
        }
        blocked.store(gate.observe(now, signals.animating, notified.exchange(false), signals.spaces,
            items ? space_windows(items) : std::vector<SpaceWindow>{}, items != nil));
        return holding();
    }
};
inline SpaceMonitor& space_monitor() { static SpaceMonitor monitor; return monitor; }
}
