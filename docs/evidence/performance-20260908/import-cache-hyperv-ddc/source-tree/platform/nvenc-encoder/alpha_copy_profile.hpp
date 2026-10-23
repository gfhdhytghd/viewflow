#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <time.h>
#include <unistd.h>

// Diagnostic only. No waits, allocation policy, or ownership changes.
namespace viewflow::gpu {
inline bool alpha_copy_profile_enabled() {
  static const bool enabled=[] { const char* v=std::getenv("VIEWFLOW_ALPHA_COPY_PROFILE"); return v && std::strcmp(v,"1")==0; }();
  return enabled;
}
inline uint64_t profile_clock_ns(clockid_t id) {
  timespec t{};
  return clock_gettime(id,&t)==0 ? uint64_t(t.tv_sec)*1000000000ULL+uint64_t(t.tv_nsec) : 0;
}
struct AlphaCopyProfile {
  const char* stage; uint64_t frame,bytes,start=0,cpu=0;
  AlphaCopyProfile(const char* name,uint64_t identity,uint64_t size):stage(name),frame(identity),bytes(size) {
    if(alpha_copy_profile_enabled()) {start=profile_clock_ns(CLOCK_MONOTONIC);cpu=profile_clock_ns(CLOCK_THREAD_CPUTIME_ID);}
  }
  ~AlphaCopyProfile() {
    if(!start) return;
    const auto endCpu=profile_clock_ns(CLOCK_THREAD_CPUTIME_ID),end=profile_clock_ns(CLOCK_MONOTONIC);
    char line[512];
    const int length=std::snprintf(line,sizeof(line),"alpha-copy-profile frame=%llu stage=%s bytes=%llu start_ns=%llu end_ns=%llu cpu_ns=%llu clocks_valid=%u\n",
      (unsigned long long)frame,stage,(unsigned long long)bytes,(unsigned long long)start,(unsigned long long)end,
      (unsigned long long)(endCpu>=cpu ? endCpu-cpu : 0),unsigned(cpu && endCpu>=cpu && end>=start));
    if(length>0 && size_t(length)<sizeof(line)) (void)::write(STDERR_FILENO,line,size_t(length));
  }
};
}
