from pathlib import Path
import shutil
base=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');a=base/'direct-source-stop';b=base/'source-mmcss';assert not b.exists();shutil.copytree(a/'source',b/'source');(b/'method').mkdir();(b/'runs').mkdir()
dest=b/'source/platform/windows-composition-preview/mmcss_scope.h';dest.parent.mkdir(parents=True);shutil.copy2('/home/wilf/data/viewflow/platform/windows-composition-preview/mmcss_scope.h',dest)
p=b/'source/platform/windows-reverse/main.cpp';s=p.read_text();needle='#include <mmsystem.h>';assert needle in s;s=s.replace(needle,needle+'\n#include "../windows-composition-preview/mmcss_scope.h"');needle='        TimerResolution timer_resolution;';assert needle in s;s=s.replace(needle,needle+'\n        viewflow::windows_preview::MmcssScope media_scheduling("reverse-source");');p.write_text(s)
for name in ['stage-build.py','build.cmd','run-source.py','analyze.py']:
 s=(a/'method'/name).read_text().replace('reverse-direct-source-stop-20260909','reverse-source-mmcss-20260909').replace('Reverse6KDirectSourceStop-20260909','Reverse6KSourceMMCSS-20260909');(b/'method'/name).write_text(s)
shutil.copy2(__file__,b/'method/prepare.py')
