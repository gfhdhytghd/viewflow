#define INITGUID
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
// Offscreen host-cost probe: no HWND, desktop target, focus, or input injection.
#define wmain viewflow_preview_entry_for_bind_profile
#include "main.cpp"
#undef wmain
#include "sparse_visual_reference.h"
#include "sparse_shared_visuals.h"
#include "sparse_visual_capture_probe.h"
int wmain(int argc, wchar_t**) try {
  init_apartment(apartment_type::single_threaded);
  DispatcherQueueOptions dq{sizeof(dq),DQTYPE_THREAD_CURRENT,DQTAT_COM_STA};
  com_ptr<ABI::Windows::System::IDispatcherQueueController> queue;
  check_hresult(CreateDispatcherQueueController(dq,queue.put()));
  Compositor compositor;
  auto owner=foreground(compositor,2048,2048);
  if(argc>1){verify_shared_sparse_pixels(compositor,owner);return 0;}
  auto a=make_gpu_surface(owner,compositor,2048,2048);
  auto b=make_gpu_surface(owner,compositor,2048,2048);
  for(uint32_t count:{32u,195u,256u}) {
    std::vector<viewflow::vfgp::AtlasPatch> patches;
    for(uint32_t i=0;i<count;++i)patches.push_back({0,(i%16)*128,(i/16)*128,(i%16)*128,(i/16)*128,128,128});
    for(bool blurred:{false,true})for(bool shared:{false,true}) {
      auto proxy=foreground_on_device(owner,compositor,2048,2048);
      CompositionBrush raw_backdrop=nullptr,backdrop=nullptr;
      if(blurred) {
        raw_backdrop=compositor.CreateBackdropBrush();
        Blur blur;blur.sigma=12;blur.Source(CompositionEffectSourceParameter(L"backdrop"));
        auto effect=compositor.CreateEffectFactory(blur).CreateBrush();
        effect.SetSourceParameter(L"backdrop",raw_backdrop);backdrop=effect;
      }
      const auto build_start=std::chrono::steady_clock::now();
      if(shared)commit_sparse_visuals(proxy,stage_sparse_visuals(proxy,compositor,a.surface,patches,0,2048,2048,raw_backdrop,blurred?12.0f:0.0f),2048,2048);
      else reference_commit_sparse_visuals(proxy,reference_stage_sparse_visuals(proxy,compositor,a.surface,patches,0,2048,2048,backdrop),2048,2048);
      const auto build_us=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-build_start).count();
      std::vector<int64_t> staged,committed;
      for(unsigned iteration=0;iteration<250;++iteration) {
        auto start=std::chrono::steady_clock::now();
        std::optional<ReferenceSparseGpuCandidate> next;
        std::optional<SparseGpuCandidate> production_next;
        if(!shared) {
          next=reference_stage_sparse_visuals(proxy,compositor,iteration%2?a.surface:b.surface,patches,0,2048,2048,backdrop);
          if(!next->reuse)throw std::runtime_error("unchanged patch layout rebuilt");
        }
        if(shared) {
          production_next=stage_sparse_visuals(proxy,compositor,iteration%2?a.surface:b.surface,patches,0,2048,2048,raw_backdrop,blurred?12.0f:0.0f);
          if(!production_next->reuse)throw std::runtime_error("production unchanged patch layout rebuilt");
        }
        auto stage_end=std::chrono::steady_clock::now();
        if(shared)commit_sparse_visuals(proxy,std::move(*production_next),2048,2048);
        else reference_commit_sparse_visuals(proxy,std::move(*next),2048,2048);
        auto end=std::chrono::steady_clock::now();
        if(iteration>=10) {
          staged.push_back(std::chrono::duration_cast<std::chrono::nanoseconds>(stage_end-start).count());
          committed.push_back(std::chrono::duration_cast<std::chrono::nanoseconds>(end-stage_end).count());
        }
      }
      std::sort(staged.begin(),staged.end());std::sort(committed.begin(),committed.end());
      std::printf("offscreen-bind shared=%u blur=%u patches=%u build_us=%lld samples=%zu stage_median_ns=%lld bind_median_ns=%lld bind_p95_ns=%lld no_physical_present=true\n",unsigned(shared),unsigned(blurred),count,(long long)build_us,committed.size(),(long long)staged[staged.size()/2],(long long)committed[committed.size()/2],(long long)committed[committed.size()*95/100]);
      std::fflush(stdout);
      for(bool repacked:{false,true}) {
      std::vector<int64_t> changed;
      size_t max_created=0,max_retargeted=0;
      for(unsigned iteration=0;iteration<40;++iteration) {
        auto layout=patches;
        if(iteration%2==0) {
          if(repacked)layout.erase(layout.begin());else layout.pop_back();
        }
        if(repacked)for(size_t i=0;i<layout.size();++i){layout[i].x=uint32_t(i%16)*128;layout[i].y=uint32_t(i/16)*128;}
        const auto start=std::chrono::steady_clock::now();
        if(shared) {
          auto candidate=stage_sparse_visuals(proxy,compositor,iteration%2?a.surface:b.surface,layout,0,2048,2048,raw_backdrop,blurred?12.0f:0.0f);
          const auto created=candidate.plan?candidate.plan->created:0;
          if(iteration>=4) {
            max_created=(std::max)(max_created,created);
            max_retargeted=(std::max)(max_retargeted,candidate.plan?candidate.plan->retargeted:size_t(0));
          }
          if(created!=(iteration%2))throw std::runtime_error("layout benchmark failed to reuse nodes");
          commit_sparse_visuals(proxy,std::move(candidate),2048,2048);
        } else {
          auto candidate=reference_stage_sparse_visuals(proxy,compositor,iteration%2?a.surface:b.surface,layout,0,2048,2048,backdrop);
          if(iteration>=4)max_created=(std::max)(max_created,candidate.visuals.size());
          reference_commit_sparse_visuals(proxy,std::move(candidate),2048,2048);
        }
        const auto elapsed=std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-start).count();
        if(iteration>=4)changed.push_back(elapsed);
      }
      std::sort(changed.begin(),changed.end());
      std::printf("offscreen-layout shared=%u blur=%u patches=%u repacked=%u max_created=%zu max_retargeted=%zu samples=%zu median_ns=%lld p95_ns=%lld no_physical_present=true\n",unsigned(shared),unsigned(blurred),count,unsigned(repacked),max_created,max_retargeted,changed.size(),(long long)changed[changed.size()/2],(long long)changed[changed.size()*95/100]);
      std::fflush(stdout);
      }
    }
  }
  return 0;
} catch(const winrt::hresult_error& e) {std::fprintf(stderr,"offscreen HRESULT=%08x\n",unsigned(e.code()));return 1;}
  catch(const std::exception& e) {std::fprintf(stderr,"offscreen error=%s\n",e.what());return 1;}
