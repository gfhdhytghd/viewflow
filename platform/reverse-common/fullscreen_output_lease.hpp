#pragma once
#include "fullscreen_dma_transition.hpp"
#include <optional>
#include <set>

namespace viewflow::reverse {
// Runtime adapter must resolve this through QueryDisplayConfig, not DISPLAYn.
struct SourceOutputIdentity {
    std::uint64_t adapter_luid{};
    std::uint32_t source_id{},target_id{};
    std::uint64_t inventory_generation{}; // Changes when topology identity changes.
    bool operator==(const SourceOutputIdentity&) const = default;
};
struct SourceRect {
    std::int32_t x{},y{};DmaExtent pixels{};
    bool operator==(const SourceRect&) const = default;
};
struct OutputLeaseRequest {
    FullscreenRouteTicket ticket{};
    SourceOutputIdentity output{};
    std::uint64_t window_incarnation{}; // HWND reuse must not target another window.
    SourceRect original_window{},leased_window{};
    bool reserved{},non_primary{},dd_supported{},exclusive{};
};
enum class OutputLeasePhase { idle, binding, ready, draining, restoring };
enum class OutputLeaseResult { accepted, busy, invalid, stale, pending, released };
// One instance per reserved output. No Win32 actions or time/focus conditions.
// Runtime owns actual DD frames and signals completion only after GPU fences.
class FullscreenOutputLease {
    std::optional<OutputLeaseRequest> lease_;
    OutputLeasePhase phase_{OutputLeasePhase::idle};
    std::set<std::uint64_t> in_flight_;
    std::uint64_t sequence_{};
    bool same(FullscreenRouteTicket ticket) const {return lease_ && lease_->ticket==ticket;}
public:
    OutputLeasePhase phase() const {return phase_;}
    const std::optional<OutputLeaseRequest>& lease() const {return lease_;}
    std::uint64_t outstanding() const {return in_flight_.size();}
    OutputLeaseResult reserve(OutputLeaseRequest r){
        if(phase_!=OutputLeasePhase::idle)return OutputLeaseResult::busy;
        if(!r.ticket.epoch || !r.ticket.target.window || !r.window_incarnation ||
           r.ticket.target.route!=FullscreenTransport::direct_dma || !r.output.inventory_generation ||
           !r.reserved || !r.non_primary || !r.dd_supported || !r.exclusive ||
           !valid_dma_extent(r.original_window.pixels) ||
           r.leased_window.pixels!=r.ticket.target.pixels || !valid_dma_extent(r.leased_window.pixels))
            return OutputLeaseResult::invalid;
        lease_=r;phase_=OutputLeasePhase::binding;return OutputLeaseResult::accepted;
    }
    OutputLeaseResult bound(FullscreenRouteTicket ticket,SourceOutputIdentity output,
                            std::uint64_t incarnation,SourceRect actual,bool exclusive){
        if(!same(ticket) || phase_!=OutputLeasePhase::binding)return OutputLeaseResult::stale;
        if(output!=lease_->output || incarnation!=lease_->window_incarnation ||
           actual!=lease_->leased_window || !exclusive){phase_=OutputLeasePhase::draining;return OutputLeaseResult::invalid;}
        phase_=OutputLeasePhase::ready;return OutputLeaseResult::accepted;
    }
    // Validate source identity and desktop isolation for every acquired DD frame;
    // an unrelated overlay invalidates DD only, leaving WGC/session available.
    OutputLeaseResult begin_frame(FullscreenRouteTicket ticket,SourceOutputIdentity output,
                                  std::uint64_t incarnation,DmaExtent actual,bool exclusive,std::uint64_t& frame_token){
        if(!same(ticket) || phase_!=OutputLeasePhase::ready)return OutputLeaseResult::stale;
        if(output!=lease_->output || incarnation!=lease_->window_incarnation ||
           actual!=lease_->ticket.target.pixels || !exclusive){phase_=OutputLeasePhase::draining;return OutputLeaseResult::invalid;}
        if(sequence_==UINT64_MAX)return OutputLeaseResult::busy;
        frame_token=++sequence_;in_flight_.insert(frame_token);return OutputLeaseResult::accepted;
    }
    OutputLeaseResult complete_frame(FullscreenRouteTicket ticket,std::uint64_t frame_token){
        if(!same(ticket) || !in_flight_.erase(frame_token))return OutputLeaseResult::stale;
        return OutputLeaseResult::accepted;
    }
    OutputLeaseResult retire(FullscreenRouteTicket ticket){
        if(!same(ticket))return OutputLeaseResult::stale;
        if(phase_!=OutputLeasePhase::restoring)phase_=OutputLeasePhase::draining;
        return !in_flight_.empty()?OutputLeaseResult::pending:OutputLeaseResult::accepted;
    }
    // Returned original bounds are an action request, not a claim of restoration.
    // Revalidate HWND incarnation in the Win32 adapter before SetWindowPos.
    std::optional<SourceRect> take_restore(){
        if(phase_!=OutputLeasePhase::draining || !in_flight_.empty())return {};
        phase_=OutputLeasePhase::restoring;return lease_->original_window;
    }
    OutputLeaseResult restored(FullscreenRouteTicket ticket,bool original_bounds_readback,
                               bool original_window_destroyed=false){
        if(!same(ticket) || phase_!=OutputLeasePhase::restoring)return OutputLeaseResult::stale;
        if(!original_bounds_readback && !original_window_destroyed)return OutputLeaseResult::pending;
        lease_.reset();phase_=OutputLeasePhase::idle;return OutputLeaseResult::released;
    }
};
}
