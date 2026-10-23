#pragma once
#include "fullscreen_dma_route.hpp"
#include <limits>
#include <optional>

namespace viewflow::reverse {
enum class FullscreenTransport { window, direct_dma };
struct FullscreenRouteTarget {
    FullscreenTransport route{FullscreenTransport::window};
    std::uint64_t window{};
    DmaExtent pixels{};
    bool operator==(const FullscreenRouteTarget&) const = default;
};
struct FullscreenRouteTicket {
    std::uint64_t epoch{};
    FullscreenRouteTarget target{};
    bool operator==(const FullscreenRouteTicket&) const = default;
};
enum class FullscreenRequestResult { unchanged, requested, invalid, epoch_exhausted };
enum class FullscreenFrameResult { stale, incomplete, update_active, activate_requested };

// Runtime-neutral handoff policy. One instance belongs to one presentation
// surface/session. The caller owns textures, keeps its last snapshot on every
// non-presenting result, and retires old GPU leases only after their work ends.
// Tickets describe route generations, not frame sequence numbers: existing
// per-route ordering still governs ordinary consecutive frames.
class FullscreenDmaTransition {
    std::uint64_t epoch_{};
    std::optional<FullscreenRouteTicket> desired_, active_;
public:
    const std::optional<FullscreenRouteTicket>& desired() const { return desired_; }
    const std::optional<FullscreenRouteTicket>& active() const { return active_; }
    bool pending() const { return desired_ && desired_ != active_; }
    // This indicates an accepted completed frame, not ownership of its pixels.
    bool has_snapshot() const { return active_.has_value(); }

    FullscreenRequestResult request(FullscreenRouteTarget target) {
        if(!target.window || !valid_dma_extent(target.pixels)) return FullscreenRequestResult::invalid;
        if(desired_ && desired_->target == target) return FullscreenRequestResult::unchanged;
        // Never alias an old ticket on integer wrap. Runtime can continue the
        // active stream; epoch exhaustion is not a session-close instruction.
        if(epoch_ == std::numeric_limits<std::uint64_t>::max()) return FullscreenRequestResult::epoch_exhausted;
        desired_ = FullscreenRouteTicket{++epoch_,target};
        return FullscreenRequestResult::requested;
    }
    FullscreenFrameResult frame(FullscreenRouteTicket ticket, bool completed) {
        const bool requested = desired_ && ticket == *desired_;
        // Continue the old route while a replacement is pending, but never
        // accept another window's updates after retargeting this surface.
        const bool current = active_ && ticket == *active_ && desired_ &&
                             ticket.target.window == desired_->target.window;
        if(!requested && !current) return FullscreenFrameResult::stale;
        if(!completed) return FullscreenFrameResult::incomplete;
        if(requested && (!active_ || *active_ != ticket)) {
            active_ = ticket;
            return FullscreenFrameResult::activate_requested;
        }
        return FullscreenFrameResult::update_active;
    }
    // A delayed failure from an obsolete attempt must not cancel a newer
    // request. An active-route failure with a fallback already pending needs
    // no second epoch. Re-enabling DMA requires a later explicit request.
    FullscreenRequestResult dma_failed(FullscreenRouteTicket failed) {
        if(!desired_ || failed != *desired_ ||
           failed.target.route != FullscreenTransport::direct_dma)
            return FullscreenRequestResult::unchanged;
        auto fallback = failed.target;
        fallback.route = FullscreenTransport::window;
        return request(fallback);
    }
};
}
