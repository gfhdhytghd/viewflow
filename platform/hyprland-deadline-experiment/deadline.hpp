#pragma once
#include <cstdint>
#include <limits>
#include <optional>

namespace viewflow::deadline {
// Scheduling only: unknown/late timing renders immediately; no frame/session
// validity cutoff. One pending deadline coalesces intervening damage events.
class Planner {
    std::optional<std::int64_t> due_;
public:
    enum class Action { immediate, arm, coalesce };
    struct Decision {Action action;std::int64_t delay_ns;};
    Decision request(std::int64_t now,std::optional<std::int64_t> presented,
                     std::int64_t period,std::int64_t lead) {
        if(due_) {
            if(now<*due_)return {Action::coalesce,*due_-now};
            due_.reset();return {Action::immediate,0};
        }
        if(now<0 || !presented || *presented<0 || *presented>now || period<=0 || lead<=0 || lead>=period ||
           *presented>std::numeric_limits<std::int64_t>::max()-period || now-*presented>=period)
            return {Action::immediate,0};
        const auto deadline=*presented+period-lead;
        if(deadline<=now)return {Action::immediate,0};
        due_=deadline;return {Action::arm,deadline-now};
    }
    bool cancel(){const bool owed=due_.has_value();due_.reset();return owed;}
    bool pending()const{return due_.has_value();}
};
}
