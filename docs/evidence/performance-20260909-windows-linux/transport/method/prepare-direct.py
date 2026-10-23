from pathlib import Path
b=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux/transport');s=(b/'source/perf_runner.cpp').read_text();old='if(argc!=2)return 2;std::wstring root=argv[1];LocalFree(argv);';new='if(argc!=3)return 2;std::wstring root=argv[1],direct=argv[2];LocalFree(argv);if(direct!=L"0" && direct!=L"1")return 2;SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_DIRECT_SINGLE_SURFACE",direct.c_str());';assert old in s;s=s.replace(old,new);(b/'source/perf_direct_runner.cpp').write_text(s)
s=(b/'method/build-runner.cmd').read_text().replace('perf_runner.cpp','perf_direct_runner.cpp').replace('viewflow_reverse_perf_runner.exe','viewflow_reverse_perf_direct_runner.exe');(b/'method/build-direct-runner.cmd').write_text(s)
s=(b/'method/run-stats.py').read_text().replace('viewflow_reverse_perf_stats_fixture.exe','viewflow_reverse_perf_waitable_fixture.exe').replace('viewflow_reverse_perf_runner.exe','viewflow_reverse_perf_direct_runner.exe')
s=s.replace("assert sys.argv[2] in ['50','0']","assert sys.argv[2] in ['0','1']")
s=s.replace('reverse-mft-inspection-20260909\\build\\Release\\viewflow_windows_reverse.exe','reverse-direct-source-20260909\\build\\Release\\viewflow_windows_reverse.exe')
s=s.replace("if sys.argv[2]=='0':wc['backend']['native']=wc['backend']['native'].replace('reverse-mft-inspection-20260909','reverse-mft-speed0-20260909')\n",'')
s=s.replace("state['quality_vs_speed']=int(sys.argv[2]);state['fixture_queue']='waitable-max-latency-1-plus-frame-statistics'","state['quality_vs_speed']=0;state['direct_single_surface']=int(sys.argv[2]);state['fixture_queue']='waitable-max-latency-1'")
s=s.replace(" -or $_.ExecutablePath -like '*reverse-mft-speed0-20260909*'"," -or $_.ExecutablePath -like '*reverse-mft-speed0-20260909*' -or $_.ExecutablePath -like '*reverse-direct-source-20260909*'")
old='-Argument \'\\\""+remote+"\\\"\' -WorkingDirectory'
new='-Argument \'\\\""+remote+"\\\" "+sys.argv[2]+"\' -WorkingDirectory'
assert old in s,old;s=s.replace(old,new)
assert 'reverse-direct-source-20260909\\build' in s
(b/'method/run-direct.py').write_text(s)
(b/'method/nested-direct.py').write_text((b/'method/nested-stats.py').read_text().replace('/run-stats.py','/run-direct.py'))
(b/'method/prepare-direct.py').write_text(Path(__file__).read_text())
