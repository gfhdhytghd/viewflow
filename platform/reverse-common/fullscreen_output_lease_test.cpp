#include "fullscreen_output_lease.hpp"
#include <cassert>
using namespace viewflow::reverse;
int main(){
    FullscreenOutputLease lease;std::uint64_t frame{};
    OutputLeaseRequest r{{1,{FullscreenTransport::direct_dma,42,{6144,3456}}},{9,2,3,1},100,
        {20,30,{800,600}},{6144,0,{6144,3456}},true,true,true,true};
    auto invalid=r;invalid.dd_supported=false;assert(lease.reserve(invalid)==OutputLeaseResult::invalid);
    assert(lease.reserve(r)==OutputLeaseResult::accepted);
    assert(lease.reserve(r)==OutputLeaseResult::busy);
    assert(lease.bound(r.ticket,r.output,100,r.leased_window,true)==OutputLeaseResult::accepted);
    assert(lease.begin_frame(r.ticket,r.output,100,{6144,3456},true,frame)==OutputLeaseResult::accepted);
    assert(lease.retire(r.ticket)==OutputLeaseResult::pending);assert(!lease.take_restore());
    auto stale=r.ticket;++stale.epoch;assert(lease.complete_frame(stale,frame)==OutputLeaseResult::stale);
    assert(lease.complete_frame(r.ticket,frame)==OutputLeaseResult::accepted);
    assert(lease.complete_frame(r.ticket,frame)==OutputLeaseResult::stale);
    assert(lease.take_restore()==r.original_window);assert(!lease.take_restore());
    assert(lease.restored(r.ticket,false)==OutputLeaseResult::pending);
    assert(lease.reserve(r)==OutputLeaseResult::busy);
    assert(lease.restored(r.ticket,true)==OutputLeaseResult::released);
    ++r.ticket.epoch;assert(lease.reserve(r)==OutputLeaseResult::accepted);
    auto other=r.output;++other.target_id;
    assert(lease.bound(r.ticket,other,100,r.leased_window,true)==OutputLeaseResult::invalid);
    assert(lease.take_restore());assert(lease.restored(r.ticket,false,true)==OutputLeaseResult::released);
    ++r.ticket.epoch;assert(lease.reserve(r)==OutputLeaseResult::accepted);
    assert(lease.bound(r.ticket,r.output,100,r.leased_window,true)==OutputLeaseResult::accepted);
    assert(lease.begin_frame(r.ticket,r.output,101,{6144,3456},true,frame)==OutputLeaseResult::invalid);
    assert(lease.take_restore());assert(lease.restored(r.ticket,false,true)==OutputLeaseResult::released);
    ++r.ticket.epoch;assert(lease.reserve(r)==OutputLeaseResult::accepted);
    assert(lease.bound(r.ticket,r.output,100,r.leased_window,true)==OutputLeaseResult::accepted);
    assert(lease.begin_frame(r.ticket,r.output,100,{6144,3456},false,frame)==OutputLeaseResult::invalid);
    assert(lease.take_restore());assert(lease.restored(r.ticket,true)==OutputLeaseResult::released);
}
