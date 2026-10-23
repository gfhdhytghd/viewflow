from pathlib import Path
import shutil
base=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');a=base/'direct-source-rt';b=base/'direct-source-stop';assert not b.exists();shutil.copytree(a/'source',b/'source');(b/'method').mkdir();(b/'runs').mkdir()
p=b/'source/platform/windows-reverse/main.cpp';s=p.read_text();needle='    bool inventory_logged{};\n    void release()';assert s.count(needle)==1;s=s.replace(needle,'''    bool inventory_logged{};
    ~App() {
        // Keep the source map's strong references while stopping callbacks.
        // Otherwise a callback can release the last Source reference after
        // map destruction and run ~Source/stop recursively on the WGC thread.
        for(auto& [_,source]:sources)source->capture.stop();
    }
    void release()''');p.write_text(s)
for name in ['stage-build.py','build.cmd','run-source.py','analyze.py']:
 s=(a/'method'/name).read_text().replace('reverse-direct-source-rt-20260909','reverse-direct-source-stop-20260909').replace('Reverse6KDirectSourceRT-20260909','Reverse6KDirectSourceStop-20260909');(b/'method'/name).write_text(s)
shutil.copy2(__file__,b/'method/prepare.py')
