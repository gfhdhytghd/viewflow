#pragma once
#include "../../desktop-handoff/core.hpp"
#include <wayland-server-core.h>
#include <memory>
#include <vector>
namespace viewflow::hyprland {
// Socket readiness shares the compositor event loop. No timer in the input path.
class DesktopHandoff {
    int fd=-1;
    wl_event_source* source{};
    handoff::Core core;
    double anchorX{},anchorY{};
    bool dead{};
    void send(handoff::Input e);
    void close();
    static int readable(int,uint32_t,void*);
public:
    DesktopHandoff(const std::string& path,handoff::Rect local,handoff::Rect remote);
    ~DesktopHandoff();
    bool finished() const { return dead; }
    inline static std::vector<std::unique_ptr<DesktopHandoff>> routes;
    inline static std::function<void(bool)> captureChanged;
    inline static std::function<bool()> legacyCaptured;
    static bool busy();
    static bool captured();
    static void motion(double x,double y,double dx,double dy);
    static bool input(handoff::Input e);
    static void restoreAnchor();
};
}
