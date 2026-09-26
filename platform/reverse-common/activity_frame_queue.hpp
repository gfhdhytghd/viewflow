#pragma once
#include "wire.hpp"
#include <deque>
#include <optional>
namespace viewflow::activity {
// Caller owns serialization. Never remove a submitted frame; only an unsent
// prediction chain can be replaced, and its successor must be a keyframe.
class FrameQueue {
    struct Record {reverse::Frame frame;std::uint64_t queued;std::size_t bytes;};
    std::deque<Record> ready_;
    std::size_t bytes_{},capacity_,byte_limit_;
    bool awaiting_keyframe_{};
public:
    std::uint64_t dropped{};
    explicit FrameQueue(std::size_t capacity=3,std::size_t byte_limit=24*1024*1024):capacity_(capacity),byte_limit_(byte_limit){}
    bool push(reverse::Frame frame,std::uint64_t now) {
        const auto bytes=frame.color.size()+frame.alpha.size();
        if(awaiting_keyframe_ && !frame.keyframe){++dropped;return true;}
        if(ready_.size()>=capacity_ || (!ready_.empty() && bytes_+bytes>byte_limit_)){
            dropped+=ready_.size();ready_.clear();bytes_=0;awaiting_keyframe_=true;
        }
        if(awaiting_keyframe_ && !frame.keyframe){++dropped;return true;}
        if(frame.keyframe)awaiting_keyframe_=false;
        bytes_+=bytes;ready_.push_back({std::move(frame),now,bytes});return false;
    }
    std::optional<reverse::Frame> pop() {
        if(ready_.empty())return {};
        auto record=std::move(ready_.front());ready_.pop_front();bytes_-=record.bytes;return std::move(record.frame);
    }
    bool empty()const{return ready_.empty();}
    std::uint64_t age(std::uint64_t now)const{return ready_.empty() || now<ready_.front().queued?0:now-ready_.front().queued;}
    bool saturated()const{return awaiting_keyframe_ || ready_.size()>=capacity_ || bytes_>=byte_limit_;}
};
}
