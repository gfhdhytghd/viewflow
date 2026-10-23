from pathlib import Path
import shutil,base64,subprocess,json
base=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');a=base/'lifecycle';b=base/'lifecycle-v2';assert not b.exists();shutil.copytree(a/'source',b/'source');(b/'method').mkdir()
p=b/'source/lifecycle_fixture.cpp';s=p.read_text();needle='auto log=[&](){std::fprintf(stderr,"lifecycle_phase';assert needle in s
s=s.replace(needle,'''auto log=[&](){
 for(auto pair:{std::pair{1,first},std::pair{2,second}}){if(!pair.second)continue;RECT rect{},client{};const bool valid=GetWindowRect(pair.second,&rect)!=FALSE;GetClientRect(pair.second,&client);std::fprintf(stderr,"lifecycle_window phase=%d index=%d valid=%u visible=%u x=%ld y=%ld width=%ld height=%ld client_width=%ld client_height=%ld\\n",phase,pair.first,unsigned(valid),unsigned(IsWindowVisible(pair.second)!=FALSE),rect.left,rect.top,rect.right-rect.left,rect.bottom-rect.top,client.right-client.left,client.bottom-client.top);if(phase==4 && pair.first==1)require(valid && rect.right-rect.left==320 && rect.bottom-rect.top==256);}
 std::fprintf(stderr,"lifecycle_phase''');s=s.replace('#include <vector>', '#include <vector>\n#include <utility>');p.write_text(s)
for name in ['build.py','build.cmd','run.py']:
 s=(a/'method'/name).read_text().replace('reverse-lifecycle-20260909','reverse-lifecycle-v2-20260909').replace('ViewflowPerf-ReverseLifecycle-','ViewflowPerf-ReverseLifecycleV2-')
 if name=='run.py':
  s=s.replace("variants={'capture-changes':'capture-changes','alpha-render':'alpha-summary-render'}", "variants={'integrated':'integrated-candidate'}")
  s=s.replace("json.loads((b.parent/variants[label]/'method/run-state.json').read_text())['binaries']", "json.loads((b.parent/variants[label]/'method/build-binaries.json').read_text())")
 (b/'method'/name).write_text(s)
(b/'method/prepare.py').write_text(Path(__file__).read_text())
remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-integrated-candidate-20260909'
s="[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';Get-ChildItem '"+remote+"\\build\\Release\\*.exe'|ForEach-Object{[pscustomobject]@{path=$_.FullName;hash=(Get-FileHash $_.FullName).Hash}}|ConvertTo-Json"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,check=True,timeout=30);(base/'integrated-candidate/method/build-binaries.json').write_text(json.dumps(json.loads(r.stdout),indent=2)+'\n');print('prepared lifecycle v2')
