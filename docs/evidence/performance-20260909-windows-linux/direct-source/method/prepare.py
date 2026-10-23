from pathlib import Path
import shutil
base=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');a=base/'mft-speed0';b=base/'direct-source';assert not b.exists();shutil.copytree(a/'source',b/'source');(b/'method').mkdir();(b/'runs').mkdir()
p=b/'source/platform/windows-reverse/main.cpp';s=p.read_text()
def replace(a,z):
 global s
 assert s.count(a)==1,(a[:80],s.count(a));s=s.replace(a,z)
replace('    ComPtr<ID3D11Texture2D> texture;','    ComPtr<ID3D11Texture2D> texture;\n    ComPtr<ID3D11ShaderResourceView> texture_view;')
replace('                    source->texture=std::move(replacement);','''                    ComPtr<ID3D11ShaderResourceView> replacement_view;
                    check(device->CreateShaderResourceView(replacement.Get(),nullptr,&replacement_view));
                    source->texture=std::move(replacement);
                    source->texture_view=std::move(replacement_view);''')
replace('        bool force_keyframe=true;','''        wchar_t direct_value[8]{};
        const bool direct_single_surface=GetEnvironmentVariableW(L"VIEWFLOW_REVERSE_DIRECT_SINGLE_SURFACE",direct_value,8)!=1 || direct_value[0]!=L'0';
        std::fprintf(stderr,"reverse_direct_single_surface enabled=%u\\n",unsigned(direct_single_surface));
        bool force_keyframe=true;''')
start=s.index('                const float clear[4]={0,0,0,0};app.context->ClearRenderTargetView')
end=s.index('                LARGE_INTEGER ticks{},frequency{};',start)
old=s[start:end]
new='''                // WGC frames are still copied during their callback. This path
                // uses our own texture and holds its producer mutex until both
                // the video conversion and alpha reads are queued on the same
                // immediate context, before the next capture may overwrite it.
                std::shared_ptr<Source> direct_source;
                std::unique_lock<std::mutex> direct_lock;
                ID3D11Texture2D* color_surface=atlas.Get();
                ID3D11ShaderResourceView* alpha_surface=atlas_view.Get();
                if(direct_single_surface && frame.tiles.size()==1) {
                    const auto& tile=frame.tiles.front();
                    if(tile.atlas_x==0 && tile.atlas_y==0 && tile.width==width && tile.height==height) {
                        direct_source=app.source_for(tile.id);
                        if(direct_source) {
                            direct_lock=std::unique_lock<std::mutex>(direct_source->mutex);
                            if(direct_source->texture && direct_source->texture_view &&
                               direct_source->geometry.content_width==width && direct_source->geometry.content_height==height) {
                                color_surface=direct_source->texture.Get();alpha_surface=direct_source->texture_view.Get();capture_pts=direct_source->pts;
                            } else {direct_lock.unlock();direct_source.reset();}
                        }
                    }
                }
                if(!direct_source) {
'''+''.join('    '+line+'\n' for line in old.rstrip().splitlines())+'''                }
'''
s=s[:start]+new+s[end:]
replace('encoder->submit(atlas.Get(),pts,force_keyframe)','encoder->submit(color_surface,pts,force_keyframe)')
replace('alpha->enqueue(atlas_view.Get(),pts)','alpha->enqueue(alpha_surface,pts)')
replace('                if(queued!=S_OK)throw std::runtime_error("alpha queue ownership mismatch");const auto alpha_end=qpc100ns();','''                if(queued!=S_OK)throw std::runtime_error("alpha queue ownership mismatch");const auto alpha_end=qpc100ns();
                if(direct_lock.owns_lock())direct_lock.unlock();
                std::fprintf(stderr,"profile_direct pts=%lld used=%u tiles=%zu\\n",pts,unsigned(bool(direct_source)),frame.tiles.size());''')
p.write_text(s)
for name in ['stage-build.py','build.cmd','run-source.py','analyze.py']:
 t=(a/'method'/name).read_text().replace('reverse-mft-speed0-20260909','reverse-direct-source-20260909').replace('Reverse6KMftSpeed0-20260909','Reverse6KDirectSource-20260909');(b/'method'/name).write_text(t)
shutil.copy2(__file__,b/'method/prepare.py')
print('prepared',b)
