#pragma once
#include "activity_frame_queue.hpp"
#include "activity_feedback.hpp"
#include "activity_input.hpp"
#include <atomic>
#include <cstdio>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
namespace viewflow::activity {
// Each worker owns one decoder. The pipe reader never waits for a background
// decoder, and overload requests a new keyframe without abandoning in-flight
// work or destroying a proxy.
class Workers {
    struct Lane {FrameQueue frames;std::mutex mutex;std::condition_variable ready;std::thread worker;};
    Lane lanes_[2];
    std::atomic<bool> stopped_{false};
    std::atomic<unsigned> finished_{};
    std::function<void(reverse::Frame)> process_;
    std::function<void(Feedback)> feedback_;
public:
    Workers(std::function<void(reverse::Frame)> process,std::function<void(Feedback)> feedback):
        process_(std::move(process)),feedback_(std::move(feedback)) {
        for(unsigned index=0;index<2;++index)lanes_[index].worker=std::thread([this,index]{
            auto& lane=lanes_[index];
            while(!stopped_){
                reverse::Frame frame{};
                {
                    std::unique_lock lock(lane.mutex);
                    lane.ready.wait(lock,[&]{return stopped_ || !lane.frames.empty();});
                    if(stopped_)break;
                    auto queued=lane.frames.pop();
                    if(!queued)continue;
                    frame=std::move(*queued);
                }
                const auto started=now_us();
                try {process_(std::move(frame));}
                catch(const std::exception& error){
                    std::fprintf(stderr,"activity decoder recovering lane=%u reason=%s\n",index,error.what());
                    feedback_({index,true,false,false,0,1});
                }
                Feedback hint{index,false,false,false,now_us()-started,1};
                {std::lock_guard lock(lane.mutex);hint.queue_us=std::max(hint.queue_us,lane.frames.age(now_us()));hint.saturated=lane.frames.saturated();}
                feedback_(hint);
            }
            ++finished_;
        });
    }
    void push(reverse::Frame frame){
        const auto index=frame.activity_epoch?frame.activity_lane:0;
        if(index>1)throw std::runtime_error("activity decoder lane");
        auto& lane=lanes_[index];Feedback hint{index,false,false,false,0,1};
        {
            std::lock_guard lock(lane.mutex);
            hint.keyframe=lane.frames.push(std::move(frame),now_us());
            hint.queue_us=lane.frames.age(now_us());hint.saturated=lane.frames.saturated();
        }
        if(hint.keyframe || hint.saturated || hint.queue_us>33333)feedback_(hint);
        lane.ready.notify_one();
    }
    void stop(){stopped_=true;for(auto& lane:lanes_)lane.ready.notify_all();}
    bool finished()const{return finished_==2;}
    ~Workers(){stop();for(auto& lane:lanes_)if(lane.worker.joinable())lane.worker.join();}
};
}
