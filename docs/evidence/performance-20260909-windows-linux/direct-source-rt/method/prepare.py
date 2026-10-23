from pathlib import Path
import shutil
base=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');a=base/'direct-source';b=base/'direct-source-rt';assert not b.exists();shutil.copytree(a/'source',b/'source');(b/'method').mkdir();(b/'runs').mkdir()
p=b/'source/platform/windows-reverse/main.cpp';s=p.read_text();needle='desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;desc.MiscFlags=0';assert s.count(needle)==1;s=s.replace(needle,'desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;desc.MiscFlags=0');p.write_text(s)
for name in ['stage-build.py','build.cmd','run-source.py','analyze.py']:
 s=(a/'method'/name).read_text().replace('reverse-direct-source-20260909','reverse-direct-source-rt-20260909').replace('Reverse6KDirectSource-20260909','Reverse6KDirectSourceRT-20260909');(b/'method'/name).write_text(s)
shutil.copy2(__file__,b/'method/prepare.py')
p=base/'transport/method/run-direct.py';s=p.read_text().replace('reverse-direct-source-20260909','reverse-direct-source-rt-20260909');p.write_text(s)
