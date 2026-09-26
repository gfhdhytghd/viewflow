#pragma once
#include <cmath>
#include <cstdint>
#include <optional>
namespace viewflow::macos {
struct GeometryRequest { std::uint64_t sequence; int x, y, width, height; };
struct PendingGeometry {
    std::optional<GeometryRequest> latest;
    void queue(GeometryRequest request) {
        if (!latest || request.sequence > latest->sequence) latest = request;
    }
    bool complete(std::uint64_t sequence) {
        if (!latest || latest->sequence != sequence) return false;
        latest.reset(); return true;
    }
};
struct WindowPlacement {
    double native_x{}, native_y{}, x{}, y{};
    bool placed{}, backing_pending{};
    double backing_x{}, backing_y{};
    void expect_backing(double nx, double ny) { backing_pending = true; backing_x = nx; backing_y = ny; }
    void observe(double nx, double ny) {
        if (backing_pending) {
            if (std::abs(nx - backing_x) <= 1 && std::abs(ny - backing_y) <= 1) backing_pending = false;
        } else if (placed) { x += nx - native_x; y += ny - native_y; }
        else { x = nx; y = ny; }
        native_x = nx; native_y = ny;
    }
    void place(double px, double py) { x = px; y = py; placed = true; }
    double pointer_x(double px) const { return native_x + px - x; }
    double pointer_y(double py) const { return native_y + py - y; }
};
}
