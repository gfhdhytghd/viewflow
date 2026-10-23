#include "async_trace.hpp"
#include <cassert>
#include <chrono>
#include <memory>
#include <string>
#include <vector>
#include <set>
struct State {std::mutex mutex;std::condition_variable cv;bool entered=false,release=false;std::vector<std::string> lines;};
void sink(const char* line,void* ptr){auto& s=*static_cast<State*>(ptr);std::unique_lock lock(s.mutex);s.entered=true;s.cv.notify_all();s.cv.wait(lock,[&]{return s.release;});s.lines.emplace_back(line);}
int main(){
 State s;auto trace=std::make_unique<vf_diag::AsyncTrace>(sink,&s);
 while(!trace->push("first\n"))std::this_thread::yield();
 {std::unique_lock lock(s.mutex);assert(s.cv.wait_for(lock,std::chrono::seconds(2),[&]{return s.entered;}));}
 // Consumer deliberately blocked. Producers must return with bounded storage.
 const auto initial_drops=trace->dropped();
 size_t accepted=0;for(size_t i=0;i<vf_diag::AsyncTrace::capacity+20;++i)accepted+=trace->push("record\n");
 assert(accepted==vf_diag::AsyncTrace::capacity);assert(trace->dropped()==initial_drops+20);
 std::string large(vf_diag::AsyncTrace::line_size,'x');assert(!trace->push(large.c_str()));assert(trace->dropped()==initial_drops+21);
 {std::lock_guard lock(s.mutex);s.release=true;}s.cv.notify_all();trace.reset();
 assert(s.lines.front()=="first\n");assert(s.lines.back()=="profile_trace_summary dropped="+std::to_string(initial_drops+21)+"\n");
 size_t records=0;for(auto& line:s.lines)if(line=="record\n")++records;assert(records==accepted);
 State concurrent;auto multi=std::make_unique<vf_diag::AsyncTrace>(sink,&concurrent);
 assert(multi->push("first\n"));
 {std::unique_lock lock(concurrent.mutex);assert(concurrent.cv.wait_for(lock,std::chrono::seconds(2),[&]{return concurrent.entered;}));}
 std::vector<std::thread> producers;
 for(unsigned t=0;t<8;++t)producers.emplace_back([&,t]{for(unsigned i=0;i<400;++i){auto line=std::to_string(t)+":"+std::to_string(i)+"\n";assert(multi->push(line.c_str()));}});
 for(auto& thread:producers)thread.join();assert(multi->dropped()==0);
 {std::lock_guard lock(concurrent.mutex);concurrent.release=true;}concurrent.cv.notify_all();multi.reset();
 std::set<std::string> unique;std::array<unsigned,8> next{};
 for(const auto& line:concurrent.lines){unsigned t,i;if(std::sscanf(line.c_str(),"%u:%u",&t,&i)!=2)continue;assert(t<8 && i==next[t]++);assert(unique.insert(line).second);}
 assert(unique.size()==3200);for(auto n:next)assert(n==400);
 std::puts("async trace: blocked sink, bounded queue, overflow reporting, 8-producer integrity/order and drain passed");
}
