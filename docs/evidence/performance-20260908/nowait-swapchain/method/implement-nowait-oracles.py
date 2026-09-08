from pathlib import Path
base=Path('platform/windows-composition-preview')
s=Path('/tmp/viewflow-inplace-pixel-test.cpp').read_text();s=s.replace('  init_apartment(apartment_type::single_threaded);','  SetEnvironmentVariableW(L"VIEWFLOW_ATLAS_NOWAIT_SWAPCHAIN",L"1");\n  init_apartment(apartment_type::single_threaded);',1)
s=s.replace('unsigned phase=0,bound_updates=0;','unsigned phase=0,bound_updates=0,swap_updates=0,busy_fallbacks=0;')
start=s.index('    if(!persistent.surface)persistent=make_gpu_surface(');end=s.index('    reference.visual.Offset(',start)
s=s[:start]+r'''    bool bound=false;
    if(persistent.surface && persistent.surface.swap) {
      auto candidate_next=stage_sparse_visuals(candidate,compositor,persistent.surface,patches,0,256,256,raw,8,flags);
      if(candidate_next.reuse) {
        const auto hr=try_copy_swapchain(owner,persistent.surface,frame,true);
        check_hresult(hr);
        if(hr==S_OK){bound=true;++bound_updates;++swap_updates;}
        else ++busy_fallbacks;
      }
    }
    if(!bound) {
      persistent=stage_gpu_surface(owner,compositor,frame,true);
      if(persistent.surface.swap)++swap_updates;
      commit_sparse_visuals(candidate,stage_sparse_visuals(candidate,compositor,persistent.surface,patches,0,256,256,raw,8,flags),256*scale,256*scale);
    }
''' +s[end:]
s=s.replace('std::printf("bound_updates=%u phases=%u\\n",bound_updates,phase);','std::printf("bound_updates=%u swap_updates=%u busy_fallbacks=%u phases=%u\\n",bound_updates,swap_updates,busy_fallbacks,phase);')
s=s.replace('if(bound_updates<42)','if(bound_updates<42 || swap_updates<70)')
(base/'sparse_coalesce_capture_test.cpp').write_text(s)
s=Path('/tmp/viewflow-before-nowait-sparse_host_backdrop_test.cpp').read_text();s=s.replace('  const bool calibrate=argc>1;','  const bool calibrate=argc>1;\n  SetEnvironmentVariableW(L"VIEWFLOW_ATLAS_NOWAIT_SWAPCHAIN",L"1");')
s=s.replace('  size_t blurred_difference=0;','  size_t blurred_difference=0;\n  GpuSurfaceCandidate persistent;unsigned bound_updates=0,swap_updates=0;')
old='    else commit_sparse_visuals(candidate,stage_sparse_visuals(candidate,compositor,surface.surface,patches,0,256,256,candidate_raw,12),256,256);'
new=r'''    else {
      bool bound=false;
      if(persistent.surface && persistent.surface.swap) {
        auto plan=stage_sparse_visuals(candidate,compositor,persistent.surface,patches,0,256,256,candidate_raw,12);
        if(plan.reuse) {
          const auto hr=try_copy_swapchain(owner,persistent.surface,frame,true);check_hresult(hr);
          if(hr==S_OK){bound=true;++bound_updates;++swap_updates;}
        }
      }
      if(!bound) {
        persistent=stage_gpu_surface(owner,compositor,frame,true);
        if(persistent.surface.swap)++swap_updates;
        commit_sparse_visuals(candidate,stage_sparse_visuals(candidate,compositor,persistent.surface,patches,0,256,256,candidate_raw,12),256,256);
      }
    }'''
assert old in s;s=s.replace(old,new)
needle='  host_require(blurred_difference'
i=s.index(needle);s=s[:i]+'  std::printf("host-swap bound_updates=%u swap_updates=%u\\n",bound_updates,swap_updates);\n  host_require(calibrate || (bound_updates>=2 && swap_updates==4),"swap path not exercised");\n'+s[i:]
(base/'sparse_host_backdrop_test.cpp').write_text(s)
# A fallback performs a real drawing copy before copy-ready is emitted.
p=base/'main.cpp';s=p.read_text().replace('''        shared_candidate=stage_gpu_surface(*sparse_atlas_,compositor_,frame);
        size_t index=0;''','''        shared_candidate=stage_gpu_surface(*sparse_atlas_,compositor_,frame);
        TraceBudget(frame.frame_identity,"copy-ready",binding->deadline);
        size_t index=0;''');p.write_text(s)
