from pathlib import Path
import shutil
b=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');p=b/'queue-depth';p.mkdir();(p/'method').mkdir()
shutil.copytree(b/'integrated-candidate/source',p/'source')
for name in ['stage-build.py','build.cmd']:
 s=(b/'integrated-candidate/method'/name).read_text().replace('reverse-integrated-candidate-20260909','reverse-queue-depth-20260909');(p/'method'/name).write_text(s)
f=p/'source/platform/windows-reverse/main.cpp';s=f.read_text();needle='        bool force_keyframe=true;';assert s.count(needle)==1;s=s.replace(needle,'''        wchar_t pending_value[8]{};
        unsigned max_pending=4;
        if(GetEnvironmentVariableW(L"VIEWFLOW_REVERSE_MAX_PENDING",pending_value,8)==1 && pending_value[0]>=L'1' && pending_value[0]<=L'4')max_pending=unsigned(pending_value[0]-L'0');
        std::fprintf(stderr,"reverse_max_pending value=%u\\n",max_pending);
'''+needle).replace('pending.size()>=4','pending.size()>=max_pending');f.write_text(s)
t=b/'transport';f=t/'source/perf_queue_runner.cpp';s=(t/'source/perf_integrated_runner.cpp').read_text().replace('changes','depth').replace('if(depth!=L"0" && depth!=L"1")','if(depth!=L"1" && depth!=L"2" && depth!=L"3" && depth!=L"4")').replace('SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_CAPTURE_CHANGES",depth.c_str());','SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_MAX_PENDING",depth.c_str());SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_CAPTURE_CHANGES",L"1");');f.write_text(s)
for name in ['build-integrated-runner.py','build-integrated-runner.cmd','run-integrated.py','nested-integrated.py']:
 s=(t/'method'/name).read_text().replace('integrated','queue')
 s=s.replace('reverse-queue-candidate-20260909','reverse-queue-depth-20260909')
 s=s.replace("assert sys.argv[2] in ['0','1']","assert sys.argv[2] in ['1','2','3','4']")
 s=s.replace("state['capture_changes']=int(sys.argv[2]);", "state['capture_changes']=1;state['max_pending']=int(sys.argv[2]);")
 (t/'method'/name.replace('integrated','queue')).write_text(s)
shutil.copy2(__file__,p/'method/prepare.py')
