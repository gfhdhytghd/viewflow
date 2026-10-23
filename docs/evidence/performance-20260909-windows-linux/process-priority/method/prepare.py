from pathlib import Path
import shutil
b=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');p=b/'process-priority';p.mkdir();(p/'method').mkdir();shutil.copytree(b/'integrated-candidate/source',p/'source')
for name in ['stage-build.py','build.cmd']:
 s=(b/'integrated-candidate/method'/name).read_text().replace('reverse-integrated-candidate-20260909','reverse-process-priority-20260909');(p/'method'/name).write_text(s)
f=p/'source/platform/windows-reverse/main.cpp';s=f.read_text();needle='        D3D_FEATURE_LEVEL level{};';assert s.count(needle)==1;s=s.replace(needle,'''        wchar_t priority_value[8]{};
        const bool normal_priority=GetEnvironmentVariableW(L"VIEWFLOW_REVERSE_NORMAL_PRIORITY",priority_value,8)==1 && priority_value[0]==L'1';
        const auto priority_before=GetPriorityClass(GetCurrentProcess());
        const bool priority_applied=!normal_priority || SetPriorityClass(GetCurrentProcess(),NORMAL_PRIORITY_CLASS);
        const auto priority_error=priority_applied?ERROR_SUCCESS:GetLastError();
        std::fprintf(stderr,"reverse_process_priority requested=%u applied=%u before=%lu after=%lu thread=%d error=%lu\\n",unsigned(normal_priority),unsigned(priority_applied),priority_before,GetPriorityClass(GetCurrentProcess()),GetThreadPriority(GetCurrentThread()),priority_error);
'''+needle);f.write_text(s)
t=b/'transport';f=t/'source/perf_priority_runner.cpp';s=(t/'source/perf_integrated_runner.cpp').read_text().replace('changes','priority').replace('SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_CAPTURE_CHANGES",priority.c_str());','SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_NORMAL_PRIORITY",priority.c_str());SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_CAPTURE_CHANGES",L"1");');f.write_text(s)
for name in ['build-integrated-runner.py','build-integrated-runner.cmd','run-integrated.py','nested-integrated.py']:
 s=(t/'method'/name).read_text().replace('integrated','priority').replace('reverse-priority-candidate-20260909','reverse-process-priority-20260909')
 s=s.replace("state['capture_changes']=int(sys.argv[2]);", "state['capture_changes']=1;state['normal_priority']=int(sys.argv[2]);")
 (t/'method'/name.replace('integrated','priority')).write_text(s)
shutil.copy2(__file__,p/'method/prepare.py')
