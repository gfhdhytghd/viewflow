#include "deadline.hpp"
#include <cassert>
using viewflow::deadline::Planner;
int main(){
    using A=Planner::Action;Planner p;constexpr auto period=16'666'667ll,lead=3'000'000ll;
    assert(p.request(0,{},period,lead).action==A::immediate);
    auto d=p.request(1'000'000,0,period,lead);assert(d.action==A::arm && d.delay_ns==12'666'667);
    // Repeated damage cannot push the deadline later.
    for(auto now:{2'000'000ll,5'000'000ll,13'000'000ll}){d=p.request(now,0,period,lead);assert(d.action==A::coalesce && now+d.delay_ns==period-lead);}
    assert(p.request(period-lead,0,period,lead).action==A::immediate && !p.pending());
    assert(p.request(period,0,period,lead).action==A::immediate);
    assert(p.request(2*period,0,period,lead).action==A::immediate);
    assert(p.request(-1,0,period,lead).action==A::immediate);
    assert(p.request(1,-1,period,lead).action==A::immediate);
    assert(p.request(10,11,period,lead).action==A::immediate);
    assert(p.request(10,0,period,period).action==A::immediate);
    assert(p.request(10,0,0,lead).action==A::immediate);
    assert(p.request(10,0,period,0).action==A::immediate);
    assert(p.request(10,0,period,lead).action==A::arm);
    assert(p.cancel() && !p.cancel());
    // A timer callback consumes exactly one outstanding render opportunity.
    assert(p.request(period+1,period,period,lead).action==A::arm);
    assert(p.cancel() && !p.pending());
    auto maximum=std::numeric_limits<std::int64_t>::max();
    assert(p.request(maximum-1,maximum-2,period,lead).action==A::immediate);
}
