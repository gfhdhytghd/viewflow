#include "progressive_frame.hpp"
#include <cassert>
#include <cstdio>
using namespace viewflow::reverse::shm;
int main(){
 ProgressiveReference first{7,1,4096,0,16,16},second{7,2,4096,0,16,16};
 assert(unpack_progressive(pack_progressive(first))==first);
 auto bytes=pack_progressive(first);bytes[0]^=1;bool rejected=false;try{unpack_progressive(bytes);}catch(...){rejected=true;}assert(rejected);
 auto invalid=first;invalid.width=16385;rejected=false;try{pack_progressive(invalid);}catch(...){rejected=true;}assert(rejected);
 ProgressiveFrame frame;assert(frame.begin(first));assert(frame.acquire(first));frame.publish_prefix(8);assert(!frame.complete());
 rejected=false;try{frame.finish();}catch(...){rejected=true;}assert(rejected);
 frame.publish_prefix(16);frame.finish();assert(frame.complete());assert(!frame.begin(second));frame.release();
 assert(frame.begin(second));assert(!frame.acquire(first));assert(frame.acquire(second));frame.release();
 frame.publish_prefix(16);frame.finish();assert(!frame.acquire(first));assert(frame.acquire(second));assert(frame.complete());frame.release();
 auto other=second;other.epoch=8;assert(frame.begin(other));assert(!frame.acquire(second));assert(frame.acquire(other));
 rejected=false;try{frame.publish_prefix(17);}catch(...){rejected=true;}assert(rejected);
 frame.publish_prefix(1);frame.abort();assert(frame.aborted());assert(!frame.begin(first));frame.release();assert(frame.begin(first));frame.abort();
 std::puts("progressive frame: version/bounds, stale reference, generation/epoch, completion and abort passed");
}
