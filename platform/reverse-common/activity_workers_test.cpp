#include "activity_workers.hpp"
#include <cassert>
#include <future>
int main(){
    using namespace viewflow::activity;
    std::promise<void> background_started,release_background,priority_completed;
    auto released=release_background.get_future().share();
    auto priority=priority_completed.get_future();auto background=background_started.get_future();
    Workers workers([&](viewflow::reverse::Frame frame){
        if(frame.activity_lane==0){background_started.set_value();released.wait();}
        else priority_completed.set_value();
    },[](Feedback){});
    viewflow::reverse::Frame frame;frame.activity_epoch=1;frame.keyframe=true;
    workers.push(frame);assert(background.wait_for(std::chrono::seconds(1))==std::future_status::ready);
    frame.activity_lane=1;workers.push(frame);
    const auto independent=priority.wait_for(std::chrono::seconds(1))==std::future_status::ready;
    release_background.set_value();assert(independent);workers.stop();
}
