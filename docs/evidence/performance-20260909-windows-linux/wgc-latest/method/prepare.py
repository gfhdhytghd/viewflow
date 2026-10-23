from pathlib import Path
import shutil
base=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');a=base/'direct-source-stop';b=base/'wgc-latest';assert not b.exists();shutil.copytree(a/'source',b/'source');(b/'method').mkdir();(b/'runs').mkdir()
p=b/'source/platform/windows-window-capture/wgc_window_capture.cpp';s=p.read_text();needle='        auto frame = sender.TryGetNextFrame();\n        if (!frame) return;';assert s.count(needle)==1;s=s.replace(needle,needle+'''
        static const bool prefer_latest=[] {
            wchar_t value[8]{};
            return GetEnvironmentVariableW(L"VIEWFLOW_WGC_LATEST_FRAME",value,8)!=1 || value[0]!=L'0';
        }();
        const auto first_time=frame.SystemRelativeTime().count();unsigned discarded=0;
        if(prefer_latest) {
            // Drain only the existing two-buffer pool. This bounded operation
            // replaces obsolete snapshots locally and never closes a session.
            for(std::int32_t i=1;i<kFramePoolBuffers;++i) {
                auto newer=sender.TryGetNextFrame();if(!newer)break;
                frame=std::move(newer);++discarded;
            }
        }
        std::fprintf(stderr,"wgc_latest enabled=%u discarded=%u first=%lld selected=%lld\\n",unsigned(prefer_latest),discarded,static_cast<long long>(first_time),static_cast<long long>(frame.SystemRelativeTime().count()));''')
s='#include <cstdio>\n'+s;p.write_text(s)
for name in ['stage-build.py','build.cmd','run-source.py','analyze.py']:
 s=(a/'method'/name).read_text().replace('reverse-direct-source-stop-20260909','reverse-wgc-latest-20260909').replace('Reverse6KDirectSourceStop-20260909','Reverse6KWgcLatest-20260909');(b/'method'/name).write_text(s)
shutil.copy2(__file__,b/'method/prepare.py')
