#include "progressive_negotiation.hpp"
#include <cassert>
#include <cstdio>
using namespace viewflow::reverse::shm;
int main(){
 ProgressiveNegotiation n;
 n.start_reader(11,1);assert(!n.confirm(11));assert(!n.agreed(11,22)); // old writer ignores offer
 n.start_writer(22);assert(n.answer(22,1));assert(!n.agreed(11,22)); // old reader never commits
 assert(n.confirm(11));assert(n.agreed(11,22));
 n.start_writer(23);assert(!n.agreed(11,23));assert(n.answer(23,1));assert(!n.agreed(11,23));
 assert(n.confirm(11));assert(n.agreed(11,23)); // writer restart requires new commit
 n.start_reader(12,1);assert(!n.agreed(12,23));assert(!n.confirm(12));
 assert(n.answer(23,1));assert(!n.agreed(12,23));assert(n.confirm(12));assert(n.agreed(12,23));
 n.start_reader(13,2);assert(n.answer(23,1));assert(!n.confirm(13));assert(!n.agreed(13,23)); // no feature intersection
 n.start_reader(14,1);n.start_writer(24);assert(n.answer(24,0));assert(!n.confirm(14));
 assert(n.answer(24,1));assert(n.confirm(14));assert(n.agreed(14,24));
 assert(!n.confirm(12));assert(!n.answer(23,1));assert(!n.agreed(12,24));assert(!n.agreed(14,23));
 bool rejected=false;try{n.start_reader(0,1);}catch(...){rejected=true;}assert(rejected);
 ProgressiveNegotiation lifecycle;
 {ProgressiveProbe writer(&lifecycle,true);
  {ProgressiveProbe reader(&lifecycle,false);assert(!writer.poll());assert(reader.poll());assert(writer.poll());}
  assert(!writer.poll());
  {ProgressiveProbe reader(&lifecycle,false);assert(!writer.poll());assert(reader.poll());assert(writer.poll());}
 }
 assert(ProgressiveNegotiation::get(lifecycle.reader.nonce)==0);
 assert(ProgressiveNegotiation::get(lifecycle.writer.writer_nonce)==0);
 std::puts("progressive negotiation: legacy silence, feature intersection, both restarts, endpoint cleanup and stale nonce rejection passed");
 {
  ProgressiveNegotiation payload{};
  ProgressiveProbe writer(&payload,true,progressive_feature|progressive_payload_feature);
  {
   ProgressiveProbe old_reader(&payload,false);
   writer.poll();old_reader.poll();assert(writer.poll());assert(!writer.payload_agreed());
  }
  {
   ProgressiveProbe reader(&payload,false,progressive_feature|progressive_payload_feature);
   writer.poll();reader.poll();assert(writer.payload_agreed());assert(reader.payload_agreed());
  }
  assert(!writer.payload_agreed());
 }
}
