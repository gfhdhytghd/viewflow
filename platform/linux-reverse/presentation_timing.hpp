#include "../reverse-common/diagnostics.hpp"
#pragma once
#include "presentation-time-client-protocol.h"
#include "presentation_counts.hpp"
#include <time.h>
#include <cstdint>
#include <algorithm>
#include <array>
#include <cstdio>
#include <map>
#include <memory>
#include <optional>
#include <vector>
#include <string>
#include <string_view>
#include <cstdlib>

namespace viewflow::reverse {
// Measurements only. Missing/delayed feedback never gates drawing or input.
class PresentationTiming {
    struct Pending {PresentationTiming* owner;std::uint64_t draw,commit;std::int64_t source_pts;std::uint64_t window_id;bool first_commit;std::string output="unknown";};
    wp_presentation* protocol_{};std::optional<clockid_t> clock_;
    std::map<struct wp_presentation_feedback*,std::unique_ptr<Pending>> pending_;
    struct Output {wl_output* proxy{};std::string name;};
    std::map<wl_output*,std::unique_ptr<Output>> outputs_;
    struct Sample {std::array<double,2> times;std::string output;std::uint32_t flags;std::int64_t source_pts;std::uint64_t presented_ns,window_id;};
    std::vector<Sample> samples_;
    std::map<std::uint64_t,std::int64_t> requested_pts_;
    PresentationCounts counts_;
    const bool count_enabled_=[] {
        const auto* setting=std::getenv("VIEWFLOW_PRESENTATION_STATS");
        return (setting && std::string_view(setting)=="1") || std::getenv("VIEWFLOW_PRESENTATION_TRACE");
    }();
    static void geometry(void*,wl_output*,int,int,int,int,int,const char*,const char*,int){}
    static void mode(void*,wl_output*,std::uint32_t,int,int,int){}
    static void done(void*,wl_output*){}
    static void scale(void*,wl_output*,int){}
    static void name(void* data,wl_output*,const char* value){static_cast<Output*>(data)->name=value;}
    static void description(void*,wl_output*,const char*){}
    inline static constexpr wl_output_listener output_listener_{geometry,mode,done,scale,name,description};
    std::uint64_t presented_{},discarded_{},invalid_{},report_at_{};std::uint32_t flags_{};
    static void clock_id(void* data,wp_presentation*,std::uint32_t clock) {static_cast<PresentationTiming*>(data)->clock_=static_cast<clockid_t>(clock);}
    static void output(void* data,struct wp_presentation_feedback*,wl_output* output){
        auto& p=*static_cast<Pending*>(data);const auto it=p.owner->outputs_.find(output);
        if(it!=p.owner->outputs_.end()) {
            const auto& name=it->second->name;
            if(p.output=="unknown")p.output=name;else if(p.output!=name)p.output="multiple";
        }
    }
    static void presented(void* data,struct wp_presentation_feedback* feedback,std::uint32_t hi,std::uint32_t lo,std::uint32_t ns,std::uint32_t,std::uint32_t,std::uint32_t,std::uint32_t flags) {
        auto& p=*static_cast<Pending*>(data);auto& self=*p.owner;
        const auto time=((std::uint64_t(hi)<<32)|lo)*1000000000ull+ns;
        const bool valid=ns<1000000000u && time>=p.commit && time>=p.draw;
        if(self.count_enabled_)self.counts_.windows[p.window_id].present(p.source_pts,time,valid,p.output);
        if(p.first_commit){++self.presented_;self.flags_|=flags;}
        if(!valid)++self.invalid_;
        else if(p.first_commit && self.samples_.size()<4096)self.samples_.push_back({{double(time-p.draw)/1e6,double(time-p.commit)/1e6},p.output,flags,p.source_pts,time,p.window_id});
        self.finish(feedback);self.report();
    }
    static void discarded(void* data,struct wp_presentation_feedback* feedback) {
        auto& p=*static_cast<Pending*>(data);auto& self=*p.owner;
        if(self.count_enabled_)++self.counts_.windows[p.window_id].discarded;
        ++self.discarded_;self.finish(feedback);self.report();
    }
    inline static constexpr wp_presentation_listener listener_{clock_id};
    inline static constexpr wp_presentation_feedback_listener feedback_listener_{output,presented,discarded};
    void finish(struct wp_presentation_feedback* f){wp_presentation_feedback_destroy(f);pending_.erase(f);}
    void report() {
        const auto time=now();if(!time)return;
        report_counts(*time);
        if(!report_at_){report_at_=*time;return;}if(*time-report_at_<5000000000ull)return;
        std::map<std::string,std::vector<const Sample*>> groups;
        for(const auto& sample:samples_)groups[sample.output].push_back(&sample);
        for(const auto& [output,group]:groups) {
            if(std::getenv("VIEWFLOW_PRESENTATION_TRACE")) {
                const auto step=std::max(std::size_t(1),(group.size()+15)/16);
                for(std::size_t i=0;i<group.size();i+=step){const auto& sample=*group[i];vf_diag::trace("ivshmem-clock-sample output=%s id=%llu atlas_submit_qpc_100ns=%lld presented_monotonic_ns=%llu clock_id=%d flags=%u first_commit=1\n",output.c_str(),(unsigned long long)sample.window_id,(long long)sample.source_pts,(unsigned long long)sample.presented_ns,int(*clock_),sample.flags);}
            }
            std::array<double,2> median{},p95{};std::uint32_t flags_union=0,flags_common=~0u;
            for(const auto* sample:group){flags_union|=sample->flags;flags_common&=sample->flags;}
            for(unsigned i=0;i<2;++i){std::vector<double> values;for(const auto* sample:group)values.push_back(sample->times[i]);std::sort(values.begin(),values.end());median[i]=values[values.size()/2];p95[i]=values[values.size()*95/100];}
            vf_diag::trace("ivshmem-presentation output=%s samples=%zu discarded_all=%llu invalid_all=%llu draw_to_present_p50_ms=%.3f draw_to_present_p95_ms=%.3f commit_to_present_p50_ms=%.3f commit_to_present_p95_ms=%.3f flags_union=%u flags_common=%u scope=host-wayland-feedback-not-photon\n",output.c_str(),group.size(),(unsigned long long)discarded_,(unsigned long long)invalid_,median[0],p95[0],median[1],p95[1],flags_union,flags_common);
        }
        samples_.clear();presented_=discarded_=invalid_=flags_=0;report_at_=*time;
    }
    void report_counts(std::uint64_t time) {
        if(!count_enabled_ || !counts_.due(time))return;
        for(const auto& [id,w]:counts_.windows) {
            std::size_t outstanding=0;for(const auto& [_,p]:pending_)if(p->window_id==id)++outstanding;
            vf_diag::trace("ivshmem-presentation-counts id=%llu output=%s interval_begin_ns=%llu interval_end_ns=%llu clock_id=%d requested=%llu presented=%llu discarded=%llu invalid=%llu untracked_commits=%llu pending=%zu unique_pts=%zu duplicate_pts=%llu first_presented_ns=%llu last_presented_ns=%llu feedback_fps=%.6f unique_source_fps=%.6f scope=per-proxy-wayland-buffer-feedback-not-photon-no-atlas-sum count_basis=feedback-arrival\n",
                (unsigned long long)id,w.output.empty()?"unknown":w.output.c_str(),(unsigned long long)counts_.interval_begin,(unsigned long long)time,int(*clock_),
                (unsigned long long)w.requested,(unsigned long long)w.presented,(unsigned long long)w.discarded,(unsigned long long)w.invalid,(unsigned long long)w.untracked,outstanding,
                w.source_pts.size(),(unsigned long long)w.duplicate_pts,(unsigned long long)w.first_ns,(unsigned long long)w.last_ns,w.feedback_fps(),w.unique_source_fps());
        }
        counts_.clear(time);
    }
public:
    // Flush even if the last frame became static and no feedback follows.
    void poll_counts() {if(count_enabled_)if(const auto time=now())report_counts(*time);}
    void bind_output(wl_registry* registry,std::uint32_t id,std::uint32_t version) {
        auto output=std::make_unique<Output>();output->name="global-"+std::to_string(id);
        output->proxy=static_cast<wl_output*>(wl_registry_bind(registry,id,&wl_output_interface,std::min(version,4u)));
        wl_output_add_listener(output->proxy,&output_listener_,output.get());outputs_.emplace(output->proxy,std::move(output));
    }
    void bind(wl_registry* registry,std::uint32_t id) {
        protocol_=static_cast<wp_presentation*>(wl_registry_bind(registry,id,&wp_presentation_interface,1));
        wp_presentation_add_listener(protocol_,&listener_,this);
    }
    std::optional<std::uint64_t> now() const {
        timespec t{};if(!clock_ || clock_gettime(*clock_,&t))return {};
        return std::uint64_t(t.tv_sec)*1000000000ull+t.tv_nsec;
    }
    void request(wl_surface* surface,std::optional<std::uint64_t> draw,std::int64_t source_pts,std::uint64_t window_id) {
        // Measurement only: retained-snapshot redraws are not new-frame latency.
        const auto previous=requested_pts_.find(window_id);
        const bool first_commit=previous==requested_pts_.end() || previous->second!=source_pts;
        if(!first_commit && !count_enabled_)return;
        requested_pts_[window_id]=source_pts; // Even when sampling capacity is exhausted.
        const auto commit=now();
        if(count_enabled_){if(commit)counts_.begin(*commit);}
        if(!protocol_ || !draw || !commit || pending_.size()>=128) {
            if(count_enabled_)++counts_.windows[window_id].untracked;
            return;
        }
        if(count_enabled_)++counts_.windows[window_id].requested;
        auto p=std::make_unique<Pending>(Pending{this,*draw,*commit,source_pts,window_id,first_commit});
        auto* f=wp_presentation_feedback(protocol_,surface);wp_presentation_feedback_add_listener(f,&feedback_listener_,p.get());pending_.emplace(f,std::move(p));
    }
    void forget_window(std::uint64_t id){requested_pts_.erase(id);}
    void reset() {
        requested_pts_.clear();counts_=PresentationCounts{};
        for(const auto& [f,_]:pending_)wp_presentation_feedback_destroy(f);pending_.clear();
        for(auto& [proxy,_]:outputs_)wl_output_destroy(proxy);outputs_.clear();
        if(protocol_)wp_presentation_destroy(protocol_);protocol_=nullptr;
    }
};
}
