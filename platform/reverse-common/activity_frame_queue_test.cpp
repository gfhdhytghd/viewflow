#include "activity_frame_queue.hpp"
#include "activity_feedback.hpp"
#include <cassert>
int main(){
    using namespace viewflow::activity;
    auto frame=[](bool key,int value){viewflow::reverse::Frame f;f.keyframe=key;f.color={static_cast<unsigned char>(value)};return f;};
    FrameQueue queue(2,8);
    assert(!queue.push(frame(true,1),1));auto inflight=queue.pop();
    assert(!queue.push(frame(false,2),2));assert(!queue.push(frame(false,3),3));
    assert(queue.push(frame(false,4),4));assert(queue.empty());assert(inflight->color[0]==1);
    assert(queue.push(frame(false,5),5));assert(!queue.push(frame(true,6),6));
    assert(queue.age(20)==14);assert(queue.pop()->color[0]==6);assert(queue.dropped==4);
    Feedback feedback{1,true,true,true,345};const auto copy=unpack_feedback(pack_feedback(feedback));
    assert(copy.lane==1 && copy.keyframe && copy.saturated && copy.single_lane && copy.queue_us==345);
}
