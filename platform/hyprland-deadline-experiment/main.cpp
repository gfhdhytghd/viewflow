// Optional scheduling experiment. Disabled until explicitly configured.
#include "deadline.hpp"
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/plugins/HookSystem.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/output/MonitorFrameScheduler.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <nlohmann/json.hpp>
#include <chrono>
#include <array>
#include <cmath>
#include <cstdio>
#include <memory>
#include <stdexcept>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
}
namespace {
using Scheduler=Monitor::CMonitorFrameScheduler;
using Clock=std::chrono::steady_clock;
std::int64_t nowNs(){return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count();}
HANDLE handle{};CFunctionHook* hook{};
void original(Scheduler* scheduler){reinterpret_cast<void(*)(Scheduler*)>(hook->m_original)(scheduler);}
struct Experiment {
    bool enabled{};std::string monitorName;std::int64_t lead=3'000'000;
    PHLMONITORREF monitor;CHyprSignalListener present;
    SP<CEventLoopTimer> timer;viewflow::deadline::Planner planner;
    std::optional<std::int64_t> lastPresent;std::int64_t lastPeriod{};
    unsigned fallbackMask{};
    std::uint64_t armed{},coalesced{},fired{},immediate{},busy{},presentations{};
    std::uint64_t presentIntervals{},longPresentIntervals{},timerLateNs{},timerLateMaxNs{},renderNs{},renderMaxNs{};
    std::uint64_t eventClockSamples{},eventClockInvalid{},eventAgeTotal{},eventAgeMax{},timerOver1ms{},cpuBudgetMisses{};
    std::array<std::array<std::int64_t,4>,4096> renderSpans{};std::size_t renderSpanCount{};
    void cancel(bool render) {
        if(timer){timer->cancel();g_pEventLoopManager->removeTimer(timer);timer.reset();}
        const bool owed=planner.cancel();
        if(render && owed)if(auto m=monitor.lock();m && m->m_frameScheduler && m->enabled() && m->m_output && !m->m_output->pendingPageFlip())original(m->m_frameScheduler.get());
    }
    void detach(bool render) {cancel(render);present.reset();monitor.reset();lastPresent.reset();lastPeriod=0;}
    void attach(const PHLMONITOR& m) {
        detach(true);monitor=m;
        present=m->m_output->events.present.listen([this](Aquamarine::IOutput::SPresentEvent event){
            // The NVIDIA path lacks HW_CLOCK. Use observed monotonic arrival,
            // explicitly an estimate, and measure outcomes via client feedback.
            if(event.presented) {
                const auto now=nowNs();
                if(event.when && event.when->tv_sec>=0 && event.when->tv_sec<=now/1'000'000'000 && event.when->tv_nsec>=0 && event.when->tv_nsec<1'000'000'000) {
                    const auto stamp=std::int64_t(event.when->tv_sec)*1'000'000'000+event.when->tv_nsec;
                    if(stamp<=now && now-stamp<1'000'000'000) {
                        const auto age=std::uint64_t(now-stamp);++eventClockSamples;eventAgeTotal+=age;eventAgeMax=std::max(eventAgeMax,age);
                    }else ++eventClockInvalid;
                }else ++eventClockInvalid;
                if(lastPresent && lastPeriod>0 && now>=*lastPresent) {
                    ++presentIntervals;
                    if(now-*lastPresent>lastPeriod+lastPeriod/2)++longPresentIntervals;
                }
                lastPresent=now;++presentations;
            }else lastPresent.reset();
        });
    }
    void frame(Scheduler* scheduler) {
        PHLMONITOR m;
        if(enabled)for(const auto& candidate:State::monitorState()->monitors())
            if(candidate->m_name==monitorName && candidate->m_frameScheduler.get()==scheduler){m=candidate;break;}
        if(!m){original(scheduler);return;}
        static auto newScheduling=CConfigValue<Config::INTEGER>("render:new_render_scheduling");
        fallbackMask=(!m->enabled()?1u:0u)|(!m->m_dpmsStatus?2u:0u)|(!m->m_output?4u:0u)|
            (m->m_output && m->m_output->state->state().adaptiveSync?8u:0u)|(m->m_tearingState.activelyTearing?16u:0u)|
            (m->m_directScanoutIsActive?32u:0u)|(*newScheduling?64u:0u);
        if(fallbackMask) {
            cancel(false);lastPresent.reset();++immediate;original(scheduler);return;
        }
        if(monitor.lock()!=m)attach(m);
        const auto period=std::isfinite(m->m_refreshRate) && m->m_refreshRate>=1.0?static_cast<std::int64_t>(1e9/m->m_refreshRate):0;
        if(lastPeriod!=period){cancel(false);lastPresent.reset();lastPeriod=period;}
        const auto decision=planner.request(nowNs(),lastPresent,period,lead);
        using Action=viewflow::deadline::Planner::Action;
        if(decision.action==Action::coalesce){++coalesced;return;}
        if(decision.action==Action::immediate){cancel(false);++immediate;original(scheduler);return;}
        ++armed;
        const auto due=nowNs()+decision.delay_ns;
        timer=makeShared<CEventLoopTimer>(std::chrono::nanoseconds(decision.delay_ns),[this,due](SP<CEventLoopTimer>,void*){
            const bool owed=planner.cancel();
            if(!owed)return;
            auto m=monitor.lock();
            if(!m || !m->m_frameScheduler || !m->enabled() || !m->m_dpmsStatus || !m->m_output)return;
            // Another commit may have occurred while the timer was pending.
            // Its flip will provide the next opportunity; never double-commit.
            if(m->m_output->pendingPageFlip()){++busy;return;}
            const auto begin=nowNs();
            const auto late=static_cast<std::uint64_t>(std::max<std::int64_t>(0,begin-due));
            timerLateNs+=late;timerLateMaxNs=std::max(timerLateMaxNs,late);
            if(late>1'000'000)++timerOver1ms;
            ++fired;original(m->m_frameScheduler.get());
            const auto duration=static_cast<std::uint64_t>(nowNs()-begin);
            if(late+duration>std::uint64_t(lead))++cpuBudgetMisses;
            if(renderSpanCount<renderSpans.size())renderSpans[renderSpanCount++]={begin,nowNs(),due,lastPresent.value_or(0)};
            renderNs+=duration;renderMaxNs=std::max(renderMaxNs,duration);
        },nullptr);
        g_pEventLoopManager->addTimer(timer);
    }
    std::string status()const {
        auto result=nlohmann::json{{"event_clock_samples",eventClockSamples},{"event_clock_invalid",eventClockInvalid},{"event_age_total_ns",eventAgeTotal},{"event_age_max_ns",eventAgeMax},{"timer_over_1ms",timerOver1ms},{"cpu_budget_misses",cpuBudgetMisses},{"enabled",enabled},{"fallback_mask",fallbackMask},{"monitor",monitorName},{"lead_ns",lead},{"armed",armed},{"coalesced",coalesced},{"fired",fired},{"immediate",immediate},{"busy",busy},{"presentations",presentations},{"present_intervals",presentIntervals},{"present_intervals_over_1p5_period",longPresentIntervals},{"timer_late_total_ns",timerLateNs},{"timer_late_max_ns",timerLateMaxNs},{"render_cpu_total_ns",renderNs},{"render_cpu_max_ns",renderMaxNs},{"pending",planner.pending()},{"clock_scope","observed-present-arrival-not-hardware-deadline"}};
        result["render_spans"]=nlohmann::json::array();
        for(std::size_t i=0;i<renderSpanCount;++i)result["render_spans"].push_back(renderSpans[i]);
        result["render_span_fields"]={"begin_ns","end_ns","due_ns","last_present_arrival_ns"};
        result["render_span_capacity"]=renderSpans.size();
        return result.dump();
    }
};
std::unique_ptr<Experiment> experiment;
void onFrame(Scheduler* scheduler){experiment->frame(scheduler);}
}
APICALL EXPORT std::string PLUGIN_API_VERSION(){return HYPRLAND_API_VERSION;}
APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE value){
    handle=value;
    if(std::string(__hyprland_api_get_hash())!=std::string(__hyprland_api_get_client_hash()))throw std::runtime_error("deadline experiment ABI mismatch");
    void* address=nullptr;
    for(const auto& match:HyprlandAPI::findFunctionsByName(handle,"onFrame"))
        if(match.demangled=="Monitor::CMonitorFrameScheduler::onFrame()"){address=match.address;break;}
    if(!address)throw std::runtime_error("deadline experiment scheduler symbol missing");
    experiment=std::make_unique<Experiment>();
    hook=HyprlandAPI::createFunctionHook(handle,address,reinterpret_cast<void*>(&onFrame));
    if(!hook || !hook->hook()){
        if(hook)HyprlandAPI::removeFunctionHook(handle,hook);
        hook=nullptr;experiment.reset();throw std::runtime_error("deadline experiment hook failed");
    }
    const bool configured=HyprlandAPI::addLuaFunction(handle,"viewflow_deadline","set",[](lua_State* L){
        const std::string name=luaL_checkstring(L,1);const bool enable=lua_toboolean(L,2);
        const double lead=luaL_optnumber(L,3,3.0);
        if(name.empty() || !std::isfinite(lead) || lead<=0 || lead>=1000)return luaL_error(L,"monitor and finite positive lead under 1000 ms required");
        experiment->enabled=false;experiment->detach(true);
        experiment->monitorName=name;experiment->lead=static_cast<std::int64_t>(lead*1e6);experiment->enabled=enable;
        lua_pushboolean(L,true);return 1;
    });
    const bool status=HyprlandAPI::addLuaFunction(handle,"viewflow_deadline","status",[](lua_State* L){const auto s=experiment->status();lua_pushlstring(L,s.data(),s.size());return 1;});
    if(!configured || !status){
        HyprlandAPI::removeLuaFunction(handle,"viewflow_deadline","set");HyprlandAPI::removeLuaFunction(handle,"viewflow_deadline","status");
        HyprlandAPI::removeFunctionHook(handle,hook);hook=nullptr;experiment.reset();throw std::runtime_error("deadline experiment Lua registration failed");
    }
    return {"viewflow-deadline-experiment","Opt-in monitor render deadline experiment","Viewflow","0.1"};
}
APICALL EXPORT void PLUGIN_EXIT(){
    std::fprintf(stderr,"viewflow-deadline-exit pending=%u\n",unsigned(experiment && experiment->planner.pending()));
    if(experiment){experiment->enabled=false;experiment->detach(true);}
    HyprlandAPI::removeLuaFunction(handle,"viewflow_deadline","set");HyprlandAPI::removeLuaFunction(handle,"viewflow_deadline","status");
    if(hook)HyprlandAPI::removeFunctionHook(handle,hook);
    hook=nullptr;experiment.reset();
}
