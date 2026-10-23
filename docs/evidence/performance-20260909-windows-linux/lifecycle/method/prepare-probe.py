from pathlib import Path
import shutil
b=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux/lifecycle');p=b/'source/platform/linux-reverse';p.mkdir(parents=True);r=b/'source/platform/reverse-common';r.mkdir()
for name in ['gpu_decoder.cpp','gpu_decoder.hpp']:shutil.copy2(Path('/home/wilf/data/viewflow/platform/linux-reverse')/name,p/name)
shutil.copy2('/home/wilf/data/viewflow/platform/reverse-common/wire.hpp',r/'wire.hpp')
s=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux/mft-speed0/method/record-probe-used.cpp').read_text();s=s.replace('#include <algorithm>','#include <algorithm>\n#include <map>')
s=s.replace('if(argc!=2 && argc!=3 && argc!=5) return 2;','if(argc!=2) return 2;')
start=s.index('        const unsigned codec_id=');end=s.index('        auto query=',start);s=s[:start]+'        const unsigned codec_id=2;\n'+s[end:]
s=s.replace('            std::vector<std::uint8_t> last_alpha;', '            std::map<std::int64_t,std::pair<unsigned,unsigned>> expected;')
s=s.replace('unsigned units=0,decoded=0,previous=0;','unsigned units=0,decoded=0;')
start=s.index('                if(frame.codec!=codec_id');end=s.index('                const auto begin=ns()',start)
s=s[:start]+'''                if(frame.codec!=codec_id)throw std::runtime_error("lifecycle codec mismatch");
                const auto alpha=viewflow::reverse::decode_alpha(frame.alpha,std::size_t(frame.width)*frame.height);
                std::vector<std::uint8_t> reference(alpha.size(),0);
                std::fprintf(stderr,"lifecycle_frame pts=%lld width=%u height=%u tiles=%zu keyframe=%u\\n",static_cast<long long>(frame.pts),frame.width,frame.height,frame.tiles.size(),unsigned(frame.keyframe));
                for(const auto& t:frame.tiles){
                    const bool stripes=t.title=="lifecycle-original" || t.title=="lifecycle-renamed";
                    if(!stripes && t.title!="lifecycle-second")throw std::runtime_error("unexpected source window");
                    for(unsigned y=0;y<t.height;++y)for(unsigned x=0;x<t.width;++x){
                        const unsigned a=stripes?(x<t.width/4?0:x<t.width/2?64:x<3*t.width/4?128:255):255;
                        reference[std::size_t(t.atlas_y+y)*frame.width+t.atlas_x+x]=static_cast<std::uint8_t>(a);
                    }
                    std::fprintf(stderr,"lifecycle_tile pts=%lld id=%llu title=%s x=%d y=%d width=%u height=%u atlas_x=%u atlas_y=%u\\n",static_cast<long long>(frame.pts),static_cast<unsigned long long>(t.id),t.title.c_str(),t.x,t.y,t.width,t.height,t.atlas_x,t.atlas_y);
                }
                if(alpha!=reference){const auto mismatch=std::mismatch(alpha.begin(),alpha.end(),reference.begin());const auto at=std::distance(alpha.begin(),mismatch.first);throw std::runtime_error("lifecycle alpha mismatch offset="+std::to_string(at)+" got="+std::to_string(*mismatch.first)+" expected="+std::to_string(*mismatch.second));}
                if(!expected.emplace(frame.pts,std::pair{frame.width,frame.height}).second)throw std::runtime_error("repeated source timestamp");
'''+s[end:]
start=s.index('                    if(image->width!=expected_width');end=s.index('\n                }\n            }',start)
s=s[:start]+'''                    const auto found=expected.find(image->pts);if(found==expected.end())throw std::runtime_error("unexpected decoded timestamp");
                    if(image->width!=found->second.first || image->height!=found->second.second)throw std::runtime_error("decoded lifecycle dimensions mismatch");
                    const auto upload_begin=ns();decoder.upload(image);const auto uploaded=ns();++decoded;
                    if(glGetError())throw std::runtime_error("lifecycle GPU upload error");
                    std::fprintf(stderr,"lifecycle_decoded pts=%lld width=%d height=%d decode_ns=%lld upload_ns=%lld\\n",static_cast<long long>(image->pts),image->width,image->height,static_cast<long long>(decode_end-begin),static_cast<long long>(uploaded-upload_begin));expected.erase(found);
'''+s[end:]
s=s.replace('opaque_alpha=verified','fixture_alpha=verified');s=s.replace('if(!units || units!=decoded)', 'if(!units || units!=decoded || !expected.empty())');(p/'lifecycle_probe.cpp').write_text(s)
(p/'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.24)
project(viewflow_reverse_lifecycle_probe LANGUAGES CXX)
find_package(PkgConfig REQUIRED)
pkg_check_modules(GPU REQUIRED IMPORTED_TARGET libavcodec libavutil egl glesv2)
find_package(CUDAToolkit REQUIRED)
add_library(viewflow_reverse_decoder STATIC gpu_decoder.cpp)
target_compile_features(viewflow_reverse_decoder PUBLIC cxx_std_20)
target_link_libraries(viewflow_reverse_decoder PUBLIC PkgConfig::GPU CUDA::cuda_driver)
add_executable(viewflow_reverse_lifecycle_probe lifecycle_probe.cpp)
target_link_libraries(viewflow_reverse_lifecycle_probe PRIVATE viewflow_reverse_decoder)
''');shutil.copy2(__file__,b/'method/prepare-probe.py')
