#pragma once
#include <windows.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>

namespace viewflow::windows {
// Keep QPC/identity tracing usable without allocating or polling GPU queries.
// Default tracing behavior is unchanged; explicit zero disables only queries.
inline bool AtlasGpuQueriesEnabled() {
  static const bool enabled=[] {
    wchar_t timing[4]{},query[2]{};
    const bool all=GetEnvironmentVariableW(L"VIEWFLOW_ATLAS_TIMINGS",timing,4)==3 && wcscmp(timing,L"all")==0;
    const bool disabled=GetEnvironmentVariableW(L"VIEWFLOW_ATLAS_GPU_QUERIES",query,2)==1 && query[0]==L'0';
    if(all)std::fprintf(stderr,"atlas-gpu-queries enabled=%u\n",unsigned(!disabled));
    return all && !disabled;
  }();
  return enabled;
}
// Diagnostics only: timestamp queries bracket GPU elapsed time. They do not
// timestamp DWM work, measure exclusive engine occupancy, or map GPU ticks to QPC.
struct GpuTimestampProbe {
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context;
  Microsoft::WRL::ComPtr<ID3D11Query> disjoint, first, last;
  uint64_t frame{}, submitted_begin_qpc{}, submitted_end_qpc{};
  const char* stage{};
  bool ended=false;
  bool Poll(std::string& output) const {
    if(!ended) return false;
    D3D11_QUERY_DATA_TIMESTAMP_DISJOINT clock{};
    uint64_t begin{},end{};
    auto hr=context->GetData(disjoint.Get(),&clock,sizeof(clock),D3D11_ASYNC_GETDATA_DONOTFLUSH);
    if(hr==S_FALSE) return false;
    if(SUCCEEDED(hr)) {hr=context->GetData(first.Get(),&begin,sizeof(begin),D3D11_ASYNC_GETDATA_DONOTFLUSH);if(hr==S_FALSE)return false;}
    if(SUCCEEDED(hr)) {hr=context->GetData(last.Get(),&end,sizeof(end),D3D11_ASYNC_GETDATA_DONOTFLUSH);if(hr==S_FALSE)return false;}
    const bool valid=hr==S_OK && !clock.Disjoint && clock.Frequency && end>=begin;
    const auto elapsed_us=valid ? double(end-begin)*1000000.0/double(clock.Frequency) : 0.0;
    output+="atlas-gpu-timestamp frame="+std::to_string(frame)+" stage="+stage+
      " status="+std::to_string(hr)+" valid="+std::to_string(valid)+
      " disjoint="+std::to_string(clock.Disjoint)+" frequency="+std::to_string(clock.Frequency)+
      " begin_ticks="+std::to_string(begin)+" end_ticks="+std::to_string(end)+
      " elapsed_us="+std::to_string(elapsed_us)+
      " submit_begin_qpc="+std::to_string(submitted_begin_qpc)+
      " submit_end_qpc="+std::to_string(submitted_end_qpc)+"\n";
    return true;
  }
};
class GpuTimestampScope {
 public:
  // Callers exclude a copy query when that frame has a shader probe: at most
  // one DISJOINT per frame, as
  // required by D3D11_QUERY. Query failures never retire the media session.
  GpuTimestampScope(ID3D11Device* device,ID3D11DeviceContext* context,
                    uint64_t frame,const char* stage,unsigned sample_remainder) noexcept {
    if(!AtlasGpuQueriesEnabled() || frame<4 || frame%20!=sample_remainder || !device || !context) return;
    try {
      auto p=std::make_shared<GpuTimestampProbe>();
      D3D11_QUERY_DESC d{D3D11_QUERY_TIMESTAMP_DISJOINT,0};
      if(FAILED(device->CreateQuery(&d,&p->disjoint))) return;
      d.Query=D3D11_QUERY_TIMESTAMP;
      if(FAILED(device->CreateQuery(&d,&p->first)) || FAILED(device->CreateQuery(&d,&p->last))) return;
      p->frame=frame;p->stage=stage;p->context=context;
      LARGE_INTEGER now{};QueryPerformanceCounter(&now);p->submitted_begin_qpc=uint64_t(now.QuadPart);
      context->Begin(p->disjoint.Get());context->End(p->first.Get());probe_=std::move(p);
    } catch(...) { /* Diagnostic allocation failure is local. */ }
  }
  ~GpuTimestampScope() {Finish();}
  GpuTimestampScope(const GpuTimestampScope&)=delete;
  GpuTimestampScope& operator=(const GpuTimestampScope&)=delete;
  std::shared_ptr<GpuTimestampProbe> Finish() noexcept {
    if(probe_ && !probe_->ended) {
      probe_->context->End(probe_->last.Get());probe_->context->End(probe_->disjoint.Get());
      LARGE_INTEGER now{};QueryPerformanceCounter(&now);probe_->submitted_end_qpc=uint64_t(now.QuadPart);probe_->ended=true;
    }
    return probe_;
  }
 private:
  std::shared_ptr<GpuTimestampProbe> probe_;
};
}
