#include "/home/wilf/data/viewflow/docs/evidence/performance-20260908/capture-phase-follow/source-prototype/platform/viewflow-capture/src/capture_commit_schedule.hpp"
#define viewflow_capture old_capture
#include "/home/wilf/data/viewflow/docs/evidence/performance-20260908/capture-commit-cadence/source-prototype/platform/viewflow-capture/src/capture_commit_schedule.hpp"
#undef viewflow_capture
#include <vector>
#include <iostream>
#include <algorithm>
#include <cstdint>
template<class S> void simulate(const char* name, const std::vector<std::uint64_t>& commits) {
 S s(60);std::uint64_t now=commits[0];size_t i=0,last=0,lastCaptured=0;std::vector<double> ages;
 while(i<commits.size()) {
  auto tick=now+s.delay(now)+25000;
  if(commits[i]<=tick) {
   now=commits[i];last=++i;
   if constexpr(requires{s.committed(now);}) s.committed(now); else s.committed();
  } else {
   now=tick;
   if(last && last!=lastCaptured) {ages.push_back(double(now-commits[last-1])/1e6);lastCaptured=last;}
   s.attempted(now);
  }
 }
 std::sort(ages.begin(),ages.end());
 std::cout<<name<<" samples="<<ages.size()<<" median_ms="<<ages[ages.size()/2]<<" p95_ms="<<ages[ages.size()*95/100]<<" max_ms="<<ages.back()<<"\n";
}
int main(){std::vector<std::uint64_t> c;std::uint64_t x;while(std::cin>>x)c.push_back(x);if(c.empty())return 2;simulate<old_capture::CaptureCommitSchedule>("old",c);simulate<viewflow_capture::CaptureCommitSchedule>("phase",c);}
