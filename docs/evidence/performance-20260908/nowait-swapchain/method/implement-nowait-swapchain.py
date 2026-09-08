from pathlib import Path
import shutil
base=Path('platform/windows-composition-preview')
files=['main.cpp','sparse_shared_visuals.h','sparse_visual_reference.h','sparse_coalesce_capture_test.cpp','sparse_host_backdrop_test.cpp']
for n in files:
 p=Path('/tmp/viewflow-before-nowait-'+n)
 if p.exists():assert p.read_bytes()==(base/n).read_bytes(),p
 else:shutil.copyfile(base/n,p)
assert (base/'main.cpp').read_bytes()==Path('/tmp/viewflow-before-inplace-main.cpp').read_bytes()
s=Path('/tmp/viewflow-inplace-main-experiment.cpp').read_text()
s=s.replace('#include <d3d11.h>','#include <d3d11.h>\n#include <dxgi1_3.h>')
s=s.replace('CompositionDrawingSurface','GpuCompositionSurface')
wrapper=r'''// A swap chain is attempted without a frame-slot wait. Drawing surfaces stay
// available for local recovery from transient Present back pressure.
struct GpuSwapChainSurface {
  com_ptr<IDXGISwapChain2> chain;
  HANDLE ready{}; // Lifetime only; the experiment never waits on this handle.
  ~GpuSwapChainSurface() { if(ready)CloseHandle(ready); }
};
struct GpuCompositionSurface {
  ICompositionSurface composition{nullptr};
  std::shared_ptr<GpuSwapChainSurface> swap;
  winrt::Windows::Foundation::Size size{};
  GpuCompositionSurface()=default;
  GpuCompositionSurface(std::nullptr_t) {}
  GpuCompositionSurface(CompositionDrawingSurface const& value)
      :composition(value),size(value?value.Size():winrt::Windows::Foundation::Size{}) {}
  explicit operator bool() const {return bool(composition);}
  operator ICompositionSurface const&() const {return composition;}
  auto Size() const {return size;}
  template<class T>auto as() const {return composition.as<T>();}
};
bool nowait_swapchain_enabled() {
  static const bool value=[] {
    wchar_t setting[2]{};
    return GetEnvironmentVariableW(L"VIEWFLOW_ATLAS_NOWAIT_SWAPCHAIN",setting,2)==1 && setting[0]==L'1';
  }();
  return value;
}
'''
s=s.replace('#include "sparse_shared_visuals.h"',wrapper+'#include "sparse_shared_visuals.h"')
s=s.replace('  GpuCompositionSurface spare_surface{nullptr};','  GpuCompositionSurface spare_surface{nullptr};\n  GpuCompositionSurface pending_swap_surface{nullptr};\n  CompositionSurfaceBrush pending_swap_brush{nullptr};')
needle='// Opt-in completion bounds: polling never waits for GPU work and never changes'
creator=r'''GpuSurfaceCandidate make_swap_gpu_surface(Foreground const& result,
    Compositor const& compositor,uint32_t width,uint32_t height) {
  GpuSurfaceCandidate candidate;
  candidate.surface.swap=std::make_shared<GpuSwapChainSurface>();
  auto dxgi=result.d3d.as<IDXGIDevice>();com_ptr<IDXGIAdapter> adapter;
  check_hresult(dxgi->GetAdapter(adapter.put()));com_ptr<IDXGIFactory2> factory;
  check_hresult(adapter->GetParent(__uuidof(IDXGIFactory2),factory.put_void()));
  DXGI_SWAP_CHAIN_DESC1 desc{};
  desc.Width=width;desc.Height=height;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count=1;desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount=2;desc.Scaling=DXGI_SCALING_STRETCH;
  desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;desc.AlphaMode=DXGI_ALPHA_MODE_PREMULTIPLIED;
  desc.Flags=DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
  com_ptr<IDXGISwapChain1> chain;
  check_hresult(factory->CreateSwapChainForComposition(result.d3d.get(),&desc,nullptr,chain.put()));
  candidate.surface.swap->chain=chain.as<IDXGISwapChain2>();
  check_hresult(candidate.surface.swap->chain->SetMaximumFrameLatency(1));
  candidate.surface.swap->ready=candidate.surface.swap->chain->GetFrameLatencyWaitableObject();
  if(!candidate.surface.swap->ready)throw hresult_error(E_FAIL);
  auto interop=compositor.as<ABI::Windows::UI::Composition::ICompositorInterop>();
  check_hresult(interop->CreateCompositionSurfaceForSwapChain(chain.get(),
      reinterpret_cast<ABI::Windows::UI::Composition::ICompositionSurface**>(put_abi(candidate.surface.composition))));
  candidate.surface.size={float(width),float(height)};
  candidate.brush=compositor.CreateSurfaceBrush(candidate.surface.composition);
  candidate.brush.Stretch(CompositionStretch::Fill);candidate.width=width;candidate.height=height;
  return candidate;
}

'''
s=s.replace(needle,creator+needle)
# Reuse the exact completion instrumentation and Flush following drawing EndDraw.
begin=s.index('  com_ptr<ID3D11DeviceContext> context;',s.index('  check_hresult(drawing->EndDraw());',s.index('void copy_gpu_frame(')))
end=s.index('\n}\n\nGpuSurfaceCandidate stage_gpu_surface(',begin)
finish=s[begin:end]
s=s[:begin]+'  finish_gpu_copy(result,frame.frame_identity);'+s[end:]
insert=s.index('void copy_gpu_frame(')
finish=finish.replace('frame.frame_identity','identity')
trycopy=r'''// S_FALSE is transient back pressure; nothing is committed on this result.
// There is deliberately no WaitForSingleObject / message-pump slot gate here.
HRESULT try_copy_swapchain(Foreground& result,GpuCompositionSurface const& surface,
    viewflow::windows::CompositedFrame const& frame,bool bound) {
  LARGE_INTEGER begin{},copied{},presented{};QueryPerformanceCounter(&begin);
  com_ptr<ID3D11Texture2D> destination;
  auto hr=surface.swap->chain->GetBuffer(0,__uuidof(ID3D11Texture2D),destination.put_void());
  if(FAILED(hr))return hr;
  com_ptr<ID3D11DeviceContext> context;result.d3d->GetImmediateContext(context.put());
  viewflow::windows::GpuTimestampScope gpu_time(result.d3d.get(),context.get(),frame.frame_identity,"swap_surface_copy",frame.shader_gpu_timing?20:10);
  hr=viewflow::windows::CopyCompositedRegion(context.get(),frame,destination.get(),0,0);
  if(FAILED(hr))return hr;
  if(auto probe=gpu_time.Finish();probe && gpu_timestamp_probes.size()<128)gpu_timestamp_probes.push_back(std::move(probe));
  destination=nullptr;QueryPerformanceCounter(&copied);
  hr=surface.swap->chain->Present(0,DXGI_PRESENT_DO_NOT_WAIT);
  QueryPerformanceCounter(&presented);
  std::fprintf(stderr,"atlas-nowait-present frame=%llu bound=%u begin_qpc=%lld copied_qpc=%lld present_qpc=%lld status=%d\n",
      static_cast<unsigned long long>(frame.frame_identity),unsigned(bound),begin.QuadPart,copied.QuadPart,presented.QuadPart,int32_t(hr));
  if(hr==DXGI_ERROR_WAS_STILL_DRAWING)return S_FALSE;
  if(FAILED(hr))return hr;
  finish_gpu_copy(result,frame.frame_identity);
  return S_OK;
}

'''
s=s[:insert]+'void finish_gpu_copy(Foreground& result,uint64_t identity) {\n'+finish+'\n}\n\n'+trycopy+s[insert:]
s=s.replace('  stage = "foreground-gpu-copy";','  stage = "foreground-gpu-copy";\n  if(surface.swap)bad("swap chain requires nonblocking copy path");',1)
start=s.index('GpuSurfaceCandidate stage_gpu_surface(');finishpos=s.index('\nvoid commit_gpu_surface(',start)
s=s[:start]+r'''GpuSurfaceCandidate stage_gpu_surface(Foreground &result,
    Compositor const &compositor,viewflow::windows::CompositedFrame const &frame,
    bool allow_swap=false) {
  static bool available=true;
  auto matches=[&](const GpuCompositionSurface& surface) {
    return surface && surface.Size().Width==float(frame.width) && surface.Size().Height==float(frame.height);
  };
  if(allow_swap && nowait_swapchain_enabled() && available) {
    GpuSurfaceCandidate attempt;
    if(matches(result.pending_swap_surface) && result.pending_swap_surface.composition!=result.surface.composition)
      attempt={std::move(result.pending_swap_surface),std::move(result.pending_swap_brush),frame.width,frame.height};
    else if(matches(result.spare_surface) && result.spare_surface.swap && result.spare_surface.composition!=result.surface.composition)
      attempt={std::move(result.spare_surface),std::move(result.spare_brush),frame.width,frame.height};
    else try {attempt=make_swap_gpu_surface(result,compositor,frame.width,frame.height);}
    catch(hresult_error const& error) {
      available=false;
      std::fprintf(stderr,"atlas-nowait-unavailable status=%d\n",int32_t(error.code()));
    }
    if(attempt.surface) {
      const auto status=try_copy_swapchain(result,attempt.surface,frame,false);
      check_hresult(status);
      if(status==S_OK)return attempt;
      result.pending_swap_surface=std::move(attempt.surface);
      result.pending_swap_brush=std::move(attempt.brush);
    }
  }
  GpuSurfaceCandidate candidate;
  if(matches(result.spare_surface) && !result.spare_surface.swap)
    candidate={std::move(result.spare_surface),std::move(result.spare_brush),frame.width,frame.height};
  else {
    result.spare_surface=nullptr;result.spare_brush=nullptr;
    candidate=make_gpu_surface(result,compositor,frame.width,frame.height);
  }
  copy_gpu_frame(result,candidate.surface,frame);
  return candidate;
}
''' +s[finishpos:]
# Base inplace experiment already deferred writes until all mapping/scene/HWND checks.
s=s.replace('inplace_requested','nowait_requested').replace('shared_in_place','shared_bound_swap')
s=s.replace('VIEWFLOW_ATLAS_INPLACE_SURFACE','VIEWFLOW_ATLAS_NOWAIT_SWAPCHAIN')
s=s.replace('nowait_requested && sparse_atlas_ && sparse_atlas_->surface &&','nowait_requested && sparse_atlas_ && sparse_atlas_->surface.swap &&')
s=s.replace('else shared_candidate=stage_gpu_surface(*sparse_atlas_,compositor_,frame);','else shared_candidate=stage_gpu_surface(*sparse_atlas_,compositor_,frame,nowait_requested);',1)
# Share local drawing fallback rebuild for geometry preflight mismatch and busy Present.
pre=s.index('    if(shared_bound_swap) {\n      shared_bound_swap=candidates.size()')
fb=s.index('      if(!shared_bound_swap) {',pre);fbend=s.index('\n    ObservePresentationTarget',fb)
block=s[fb:fbend]
assert block.endswith('    }')
body=block[block.index('        shared_candidate='):block.rindex('      }')]
# Closing remainder belongs to outer preflight; body is a valid lambda block.
lambda_block='    auto drawing_fallback=[&] {\n'+body+'    };\n'
s=s[:pre]+lambda_block+s[pre:fb]+'      if(!shared_bound_swap)drawing_fallback();\n    }\n'+s[fbend:]
old='''      visual_mutated=true;
      copy_gpu_frame(*sparse_atlas_,shared_candidate->surface,frame);'''
new='''      const auto status=try_copy_swapchain(*sparse_atlas_,shared_candidate->surface,frame,true);
      check_hresult(status);
      if(status==S_FALSE) {
        shared_bound_swap=false;
        drawing_fallback();
        ObservePresentationTarget(frame.frame_identity,frame.width,frame.height);
      } else visual_mutated=true;'''
assert old in s;s=s.replace(old,new,1)
s=s.replace('"atlas-inplace-surface frame="','"atlas-nowait-surface frame="')
s=s.replace('" applied="+std::to_string(shared_bound_swap)+"\\n"','" bound="+std::to_string(shared_bound_swap)+" swap="+std::to_string(shared_candidate && bool(shared_candidate->surface.swap))+"\\n"')
# Emit copy-ready only after the deferred actual copy. Existing proxy-ready still
# means proxy preparation; no log claims GPU completion before the copy.
s=s.replace('      TraceBudget(frame.frame_identity, "copy-ready", binding->deadline);','      if(!shared_bound_swap)TraceBudget(frame.frame_identity, "copy-ready", binding->deadline);')
needle='    if(nowait_requested && frame.frame_identity%60==0)'
s=s.replace(needle,'    if(shared_bound_swap)TraceBudget(frame.frame_identity,"copy-ready",binding->deadline);\n'+needle)
s=s.replace('IGpuCompositionSurfaceInterop','ICompositionDrawingSurfaceInterop')
(base/'main.cpp').write_text(s)
for n in ['sparse_shared_visuals.h','sparse_visual_reference.h']:
 p=base/n;p.write_text(p.read_text().replace('CompositionDrawingSurface','GpuCompositionSurface'))
shutil.copyfile('/tmp/viewflow-inplace-stable_surface_layout.h',base/'stable_surface_layout.h')
print('nowait candidate prepared')
