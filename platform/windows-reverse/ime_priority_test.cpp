#include "ime_priority.hpp"
#include <cassert>
int main(){
 viewflow::reverse::ImePriority p;
 // A key arrives just after a normal 50ms inventory pass: wake changes now,
 // and stale queued frames must drain before admitting another frame.
 const auto before=p.wake();p.activity(101);
 assert(p.wake()!=before && p.inventory_ms(101,false)==8);
 assert(p.pending_limit(101,4)==1);
 // The first candidate capture may arrive before the next 60Hz deadline.
 const auto first=p.urgent();p.first_frame();assert(p.urgent()!=first);
 // Reading readiness does not consume it while encoder capacity is busy.
 assert(p.urgent()!=first && p.pending_limit(200,4)==1);
 // Sustained typing extends the preference, then normal body capacity returns.
 p.activity(590);assert(p.active(700));assert(!p.active(1090));
 assert(p.inventory_ms(1090,false)==50 && p.pending_limit(1090,4)==4);
 assert(p.inventory_ms(1090,true)==8);
}
