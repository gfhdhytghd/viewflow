#include "progressive_state.hpp"
#include <array>
#include <cassert>
#include <cstdio>
#include <thread>
using viewflow::reverse::shm::ProgressiveState;
int main(){
 // Exhaustive recovery table, including idempotence and opposite-side leases.
 constexpr std::array<std::uint64_t,7> writer_after{0,0,0,5,4,5,0};
 constexpr std::array<std::uint64_t,7> reader_after{0,1,0,1,0,0,6};
 for(unsigned before=0;before<7;++before){
   ProgressiveState writer;writer.state=before;writer.rows=17;writer.recover(true);
   assert(writer.state==writer_after[before] && writer.rows==17);writer.recover(true);assert(writer.state==writer_after[before]);
   ProgressiveState reader;reader.state=before;reader.rows=17;reader.recover(false);
   assert(reader.state==reader_after[before] && reader.rows==17);reader.recover(false);assert(reader.state==reader_after[before]);
 }
 // Reader recovery may race the still-live writer finishing/aborting. Both
 // endpoints must end in a reusable slot or a complete unclaimed frame.
 for(unsigned i=0;i<200;++i){
   ProgressiveState raced;assert(raced.begin());raced.announce();assert(raced.acquire());raced.publish_prefix(1);
   std::thread finish([&]{raced.finish_writer(i%2==0);});raced.recover(false);finish.join();
   assert(raced.state==ProgressiveState::free || (i%2==0 && raced.state==ProgressiveState::ready));
 }

 ProgressiveState hidden;assert(hidden.begin());assert(!hidden.acquire());hidden.finish_writer(false);
 // A reader may consume the committed prefix while the writer is alive,
 // but neither completion nor cancellation can release its storage early.
 ProgressiveState s;assert(s.begin());s.announce();assert(s.acquire());assert(!s.acquire());assert(!s.complete());
 s.publish_prefix(1);assert(s.available_rows()==1);s.finish_writer(false);
 assert(s.aborted());assert(!s.begin());s.release_reader();assert(s.begin());s.announce();
 assert(s.available_rows()==0);s.publish_prefix(2);s.finish_writer(true);
 assert(!s.begin());assert(s.acquire());assert(s.complete());s.release_reader();
 assert(s.begin());s.announce();assert(s.acquire());s.release_reader();s.finish_writer(false);assert(s.begin());s.announce();s.finish_writer(false);
 bool rejected=false;assert(s.begin());s.announce();s.publish_prefix(1);try{s.publish_prefix(1);}catch(...){rejected=true;}assert(rejected);s.finish_writer(false);
 // Repeated producer/consumer races: every released prefix must expose all of
 // its pixel writes, and the next generation cannot begin before reader release.
 std::array<unsigned,256> pixels{};constexpr unsigned rounds=2000;
 std::atomic<unsigned> announced=0,retired=0;
 std::thread producer([&]{for(unsigned gen=1;gen<=rounds;++gen){
   while(retired.load(std::memory_order_acquire)!=gen-1)std::this_thread::yield();
   assert(s.begin());s.announce();announced.store(gen,std::memory_order_release);
   for(unsigned row=0;row<pixels.size();++row){pixels[row]=gen*1000+row;s.publish_prefix(row+1);if(row%17==0)std::this_thread::yield();}
   s.finish_writer(true);
 }});
 for(unsigned gen=1;gen<=rounds;++gen){
   while(announced.load(std::memory_order_acquire)!=gen)std::this_thread::yield();
   assert(s.acquire());unsigned checked=0;
   while(!s.complete()){const auto rows=s.available_rows();while(checked<rows){assert(pixels[checked]==gen*1000+checked);++checked;}std::this_thread::yield();}
   assert(s.available_rows()==pixels.size());while(checked<pixels.size()){assert(pixels[checked]==gen*1000+checked);++checked;}
   assert(!s.begin());s.release_reader();retired.store(gen,std::memory_order_release);
 }
 producer.join();std::puts("progressive ownership: prefix visibility, cancellation, exclusivity, recovery races and2000concurrent generations passed");
}
