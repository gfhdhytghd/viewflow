from pathlib import Path
import shutil
base=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');a=base/'alpha-summary-render';b=base/'integrated-candidate';assert not b.exists();shutil.copytree(a/'source',b/'source');(b/'method').mkdir();(b/'runs').mkdir();p=b/'source/platform/windows-reverse'
(p/'frame_changes.hpp').write_text('''#pragma once
#include "../reverse-common/wire.hpp"
#include <algorithm>
#include <map>
#include <tuple>
namespace viewflow::reverse {
// Skip only unchanged content AND unchanged window metadata. A periodic
// unchanged refresh is allowed; no capture age terminates a window/session.
class FrameChangeTracker {
 public:
  using Versions=std::map<std::uint64_t,std::uint64_t>;
  bool needs_frame(const std::vector<Tile>& tiles,const Versions& versions,bool keyframe,bool refresh) const {
    if(keyframe || refresh || versions!=versions_ || tiles.size()!=tiles_.size())return true;
    return !std::equal(tiles.begin(),tiles.end(),tiles_.begin(),[](const Tile& a,const Tile& b){
      const auto fields=[](const Tile& t){return std::tie(t.id,t.owner,t.x,t.y,t.width,t.height,t.atlas_x,t.atlas_y,t.title,t.flags,t.geometry_ack);};
      return fields(a)==fields(b);
    });
  }
  // Commit only the versions actually copied/submitted, after input acceptance.
  // A newer callback version arriving in the meantime remains pending work.
  void submitted(const std::vector<Tile>& tiles,Versions versions){tiles_=tiles;versions_=std::move(versions);}
 private:
  std::vector<Tile> tiles_;
  Versions versions_;
};
}
''')
(p/'frame_changes_test.cpp').write_text('''#include "frame_changes.hpp"
#include <cassert>
using namespace viewflow::reverse;
int main(){
 FrameChangeTracker c;Tile t{1,0,10,20,6144,3456,0,0,"sample",0,0};std::vector<Tile> tiles{t};FrameChangeTracker::Versions v{{1,1}};
 assert(c.needs_frame(tiles,v,false,false));c.submitted(tiles,v);assert(!c.needs_frame(tiles,v,false,false));
 assert(c.needs_frame(tiles,v,true,false));assert(c.needs_frame(tiles,v,false,true));
 // New pixels, including a callback that races the prior GPU submission.
 auto next=v;next[1]=2;assert(c.needs_frame(tiles,next,false,false));c.submitted(tiles,v);assert(c.needs_frame(tiles,next,false,false));c.submitted(tiles,next);assert(!c.needs_frame(tiles,next,false,false));
 // Geometry, layout, title, owner, drag/IME flags, and acknowledgments still flow.
 for(int field=0;field<11;++field){auto changed=tiles;auto& a=changed[0];switch(field){case 0:++a.id;break;case 1:++a.owner;break;case 2:++a.x;break;case 3:++a.y;break;case 4:++a.width;break;case 5:++a.height;break;case 6:++a.atlas_x;break;case 7:++a.atlas_y;break;case 8:a.title+=" updated";break;case 9:++a.flags;break;case 10:++a.geometry_ack;break;}assert(c.needs_frame(changed,next,false,false));}
 // Closing the final window emits removal metadata; subsequent idle preserves it.
 assert(c.needs_frame({}, {},false,false));c.submitted({},{});assert(!c.needs_frame({}, {},false,false));assert(c.needs_frame({}, {},false,true));assert(c.needs_frame(tiles,next,false,false));
 // A tile whose source copy was unavailable must be retried, not marked consumed.
 c.submitted(tiles,{});assert(c.needs_frame(tiles,next,false,false));
}
''')
s=(p/'main.cpp').read_text();s='#include "frame_changes.hpp"\n'+s
s=s.replace('std::int64_t pts{};bool dirty{},closed{}','std::uint64_t capture_version{};std::int64_t pts{};bool closed{}')
s=s.replace('source->dirty=true;','++source->capture_version;')
needle='        bool force_keyframe=true;';assert s.count(needle)==1
s=s.replace(needle,'''        wchar_t changes_value[8]{};
        const bool capture_changes=GetEnvironmentVariableW(L"VIEWFLOW_REVERSE_CAPTURE_CHANGES",changes_value,8)!=1 || changes_value[0]!=L'0';
        std::fprintf(stderr,"reverse_capture_changes enabled=%u\\n",unsigned(capture_changes));
        vf::FrameChangeTracker changes;std::uint64_t unchanged_skips=0;
        Clock::time_point last_submission{};
'''+needle)
s=s.replace('vf::Frame frame;unsigned row_x=0', 'vf::Frame frame;vf::FrameChangeTracker::Versions observed_versions,copied_versions;unsigned row_x=0')
needle='                    row_x+=w;row_height=std::max(row_height,h);';assert needle in s;s=s.replace(needle,'                    observed_versions[source->id]=source->capture_version;\n'+needle)
needle='                needed_width=(needed_width+63)&~63u;';assert needle in s;s=s.replace(needle,'''                const bool periodic_refresh=Clock::now()-last_submission>=std::chrono::seconds(1);
                if(capture_changes && !changes.needs_frame(frame.tiles,observed_versions,force_keyframe,periodic_refresh)){
                    ++unchanged_skips;std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;
                }
'''+needle)
needle='color_surface=direct_source->texture.Get();alpha_surface=direct_source->texture_view.Get();capture_pts=direct_source->pts;';assert s.count(needle)==1;s=s.replace(needle,needle+'copied_versions[direct_source->id]=direct_source->capture_version;')
needle='source->texture.Get(),0,nullptr);capture_pts=source->pts;';assert s.count(needle)==1;s=s.replace(needle,needle+'copied_versions[source->id]=source->capture_version;')
needle='                if(direct_lock.owns_lock())direct_lock.unlock();';assert s.count(needle)==1;s=s.replace(needle,'''                changes.submitted(frame.tiles,std::move(copied_versions));last_submission=Clock::now();
                std::fprintf(stderr,"profile_capture_changes pts=%lld enabled=%u unchanged_skips=%llu periodic=%u\\n",pts,unsigned(capture_changes),static_cast<unsigned long long>(unchanged_skips),unsigned(periodic_refresh));
'''+needle)
(p/'main.cpp').write_text(s)
with (p/'CMakeLists.txt').open('a') as f:f.write('''
add_executable(viewflow_reverse_frame_changes_test frame_changes_test.cpp)
target_compile_features(viewflow_reverse_frame_changes_test PRIVATE cxx_std_20)
target_compile_options(viewflow_reverse_frame_changes_test PRIVATE /UNDEBUG /we4700 /we4701)
add_test(NAME reverse_frame_changes COMMAND viewflow_reverse_frame_changes_test)
''')
for name in ['stage-build.py','build.cmd','run-source.py','analyze.py']:
 s=(base/'alpha-summary-render/method'/name).read_text().replace('reverse-alpha-summary-render-20260909','reverse-integrated-candidate-20260909').replace('Reverse6KAlphaSummaryRender-20260909','Reverse6KIntegratedCandidate-20260909');(b/'method'/name).write_text(s)
p=b/'method/build.cmd';s=p.read_text().replace('--parallel 2','viewflow_reverse_frame_changes_test --parallel 2');s=s.replace('exit /b %errorlevel%\n','exit /b %errorlevel%\n',1)
s=s.rsplit('exit /b %errorlevel%',1)[0]+'''if errorlevel 1 exit /b %errorlevel%
"C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\CMake\\bin\\ctest.exe" --test-dir build -C Release -R reverse_frame_changes --output-on-failure
exit /b %errorlevel%
''';p.write_text(s)
shutil.copy2(__file__,b/'method/prepare.py');print('prepared capture changes candidate',b)
